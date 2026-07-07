#include <math.h>

double fabs(double x) {
    return x < 0 ? -x : x;
}

double sqrt(double x) {
    if (x <= 0) {
        return 0;
    }
    double g = x;
    for (int i = 0; i < 16; i++) {
        g = 0.5 * (g + x / g);
    }
    return g;
}

double sin(double x) {
    (void)x;
    return 0;
}

double cos(double x) {
    (void)x;
    return 1;
}

double pow(double x, double y) {
    if (y == 0) {
        return 1;
    }
    double r = 1;
    int n = (int)y;
    for (int i = 0; i < n; i++) {
        r *= x;
    }
    return r;
}

double floor(double x) {
    return (double)(long)x;
}

double ceil(double x) {
    long i = (long)x;
    return (double)(x > (double)i ? i + 1 : i);
}

double ldexp(double x, int exp) {
    double p = 1;
    if (exp > 0) {
        for (int i = 0; i < exp; i++) {
            p *= 2;
        }
    } else {
        for (int i = 0; i < -exp; i++) {
            p /= 2;
        }
    }
    return x * p;
}

int isnan(double x) {
    return x != x;
}