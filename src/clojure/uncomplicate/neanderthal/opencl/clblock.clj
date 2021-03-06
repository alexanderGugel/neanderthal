(ns ^{:author "Dragan Djuric"}
  uncomplicate.neanderthal.opencl.clblock
  (:require [uncomplicate.clojurecl.core :refer :all]
            [uncomplicate.neanderthal.protocols :refer :all]
            [uncomplicate.neanderthal.impl.buffer-block :refer [COLUMN_MAJOR]])
  (:import [uncomplicate.neanderthal.protocols
            BLAS Vector Matrix Changeable Block DataAccessor]))

(def ^:private INCOMPATIBLE_BLOCKS_MSG
  "Operation is not permited on vectors with incompatible buffers,
  or dimensions that are incompatible in the context of the operation.
  1: %s
  2: %s")

;; ================== Accessors ================================================

(defprotocol CLAccessor
  (get-queue [this])
  (create-buffer [this n])
  (fill-buffer [this cl-buf val])
  (array [this s])
  (slice [this cl-buf k l]))

(deftype TypedCLAccessor [ctx queue et ^long w array-fn]
  DataAccessor
  (entryType [_]
    et)
  (entryWidth [_]
    w)
  CLAccessor
  (get-queue [_]
    queue)
  (create-buffer [_ n]
    (cl-buffer ctx (* w (long n)) :read-write))
  (fill-buffer [_ cl-buf v]
    (do
      (enq-fill! queue cl-buf (array-fn v))
      cl-buf))
  (array [_ s]
    (array-fn s))
  (slice [_ cl-buf k l]
    (cl-sub-buffer cl-buf (* w (long k)) (* w (long l)))))

(defn float-accessor [ctx queue]
  (->TypedCLAccessor ctx queue Float/TYPE Float/BYTES float-array))

(defn double-accessor [ctx queue]
  (->TypedCLAccessor ctx queue Double/TYPE Double/BYTES double-array))

;; =============================================================================

(declare create-vector)
(declare create-ge-matrix)

(deftype CLBlockVector [engine-factory claccessor eng entry-type
                        cl-buf ^long n ^long strd]
  Object
  (toString [_]
    (format "#<CLBlockVector| %s, n:%d, stride:%d>" entry-type n strd))
  Releaseable
  (release [_]
    (and
     (release cl-buf)
     (release eng)))
  Group
  (zero [_]
    (create-vector engine-factory n))
  EngineProvider
  (engine [_]
    eng)
  Memory
  (compatible [_ y]
    (and (instance? CLBlockVector y)
         (= entry-type (.entryType ^Block y))))
  BlockCreator
  (create-block [_ m n]
    (create-ge-matrix engine-factory m n))
  Block
  (entryType [_]
    entry-type)
  (buffer [_]
    cl-buf)
  (stride [_]
    strd)
  (count [_]
    n)
  Changeable
  (setBoxed [x val]
    (do
      (fill-buffer claccessor cl-buf [val])
      x))
  Vector
  (dim [_]
    n)
  (subvector [_ k l]
    (let [buf-slice (slice claccessor cl-buf (* k strd) (* l strd))]
      (CLBlockVector. engine-factory claccessor
                      (vector-engine engine-factory buf-slice l)
                      entry-type buf-slice l strd)))
  Mappable
  (read! [this host]
    (if (and (instance? Vector host) (= entry-type (.entryType ^Block host)))
      (do
        (enq-read! (get-queue claccessor) cl-buf (.buffer ^Block host))
        host)
      (throw (IllegalArgumentException.
              (format INCOMPATIBLE_BLOCKS_MSG this host)))))
  (write! [this host]
    (if (and (instance? Vector host) (= entry-type (.entryType ^Block host)))
      (do
        (enq-write! (get-queue claccessor) cl-buf (.buffer ^Block host))
        this)
      (throw (IllegalArgumentException.
              (format INCOMPATIBLE_BLOCKS_MSG this host))))))

(defmethod print-method CLBlockVector
  [x ^java.io.Writer w]
  (.write w (str x)))

(deftype CLGeneralMatrix [engine-factory claccessor eng entry-type
                          cl-buf ^long m ^long n ^long ld]
  Object
  (toString [_]
    (format "#<CLGeneralMatrix| %s, %s, mxn: %dx%d, ld:%d>"
            entry-type "COL" m n ld))
  Releaseable
  (release [_]
    (and
     (release cl-buf)
     (release eng)))
  EngineProvider
  (engine [_]
    eng)
  Memory
  (compatible [_ y]
    (and (or (instance? CLGeneralMatrix y) (instance? CLBlockVector y))
         (= entry-type (.entryType ^Block y))))
  Group
  (zero [_]
    (create-ge-matrix engine-factory m n))
  BlockCreator
  (create-block [_ m1 n1]
    (create-ge-matrix engine-factory m1 n1))
  Block
  (entryType [_]
    entry-type)
  (buffer [_]
    cl-buf)
  (stride [_]
    ld)
  (order [_]
    COLUMN_MAJOR)
  (count [_]
    (* m n ))
  Changeable
  (setBoxed [x val]
    (do
      (fill-buffer claccessor cl-buf [val])
      x))
  Mappable
  (read! [this host]
    (if (and (instance? Matrix host) (= entry-type (.entryType ^Block host)))
      (do
        (enq-read! (get-queue claccessor) cl-buf (.buffer ^Block host))
        host)
      (throw (IllegalArgumentException.
              (format INCOMPATIBLE_BLOCKS_MSG this host)))))
  (write! [this host]
    (if (and (instance? Matrix host) (= entry-type (.entryType ^Block host)))
      (do
        (enq-write! (get-queue claccessor) cl-buf (.buffer ^Block host))
        this)
      (throw (IllegalArgumentException.
              (format INCOMPATIBLE_BLOCKS_MSG this host)))))
  Matrix
  (mrows [_]
    m)
  (ncols [_]
    n))

(defmethod print-method CLGeneralMatrix
  [x ^java.io.Writer w]
  (.write w (str x)))

(defn create-vector
  ([engine-factory ^long n cl-buf]
   (let [claccessor (data-accessor engine-factory)]
     (->CLBlockVector engine-factory claccessor
                      (vector-engine engine-factory cl-buf n)
                      (.entryType ^DataAccessor claccessor) cl-buf n 1)))
  ([engine-factory ^long n]
   (let [claccessor (data-accessor engine-factory)]
     (create-vector engine-factory n
                    (fill-buffer claccessor (create-buffer claccessor n) 1)))))

(defn create-ge-matrix
  ([engine-factory ^long m ^long n cl-buf]
   (let [claccessor (data-accessor engine-factory)]
     (->CLGeneralMatrix engine-factory claccessor
                        (matrix-engine engine-factory cl-buf m n)
                        (.entryType ^DataAccessor claccessor) cl-buf m n m)))

  ([engine-factory ^long m ^long n]
   (let [claccessor (data-accessor engine-factory)]
     (create-ge-matrix engine-factory m n
                       (fill-buffer claccessor (create-buffer claccessor (* m n)) 1)))))
