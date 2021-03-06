package uncomplicate.neanderthal.protocols;

public interface BLAS {

    long iamax (Block x);

    void rotg (Block x);

    void rotmg (Block p, Block args);

    void rotm (Block x, Block y, Block p);

    void swap (Block x, Block y);

    void copy (Block x, Block y);

    Object dot (Block x, Block y);

    Object nrm2 (Block x);

    Object asum (Block x);

    void rot (Block x, Block y, double c, double s);

    void scal (Object alpha, Block x);

    void axpy (Object alpha, Block x, Block y);

    void mv (Object alpha, Block a, Block x, Object beta, Block y);

    void rank (Object alpha, Block x, Block y, Block a);

    void mm (Object alpha, Block a, Block b, Object beta, Block c);

}
