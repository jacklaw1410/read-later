#include "CGzip.h"

#include <stdio.h>
#include <string.h>
#include <zlib.h>

#define PACK_GZIP_CHUNK (1u << 16)

static void pack_fail(char *err, size_t errLen, const char *msg) {
    if (err != NULL && errLen > 0) {
        snprintf(err, errLen, "%s", msg ? msg : "unknown gzip failure");
    }
}

int pack_gunzip(const char *srcPath, const char *dstPath, char *err, size_t errLen) {
    gzFile in = gzopen(srcPath, "rb");
    if (in == NULL) {
        pack_fail(err, errLen, "cannot open archive for reading");
        return 1;
    }
    FILE *out = fopen(dstPath, "wb");
    if (out == NULL) {
        gzclose(in);
        pack_fail(err, errLen, "cannot open output for writing");
        return 2;
    }
    unsigned char buf[PACK_GZIP_CHUNK];
    int n = 0;
    while ((n = gzread(in, buf, sizeof(buf))) > 0) {
        if (fwrite(buf, 1, (size_t)n, out) != (size_t)n) {
            gzclose(in);
            fclose(out);
            pack_fail(err, errLen, "write failed (disk full?)");
            return 2;
        }
    }
    int zerr = Z_OK;
    const char *zmsg = gzerror(in, &zerr);
    gzclose(in);
    if (fclose(out) != 0) {
        pack_fail(err, errLen, "close failed (disk full?)");
        return 2;
    }
    if (n < 0 || (zerr != Z_OK && zerr != Z_STREAM_END)) {
        pack_fail(err, errLen, zmsg);
        return 3;
    }
    return 0;
}

int pack_gzip(const char *srcPath, const char *dstPath, char *err, size_t errLen) {
    FILE *in = fopen(srcPath, "rb");
    if (in == NULL) {
        pack_fail(err, errLen, "cannot open input for reading");
        return 1;
    }
    gzFile out = gzopen(dstPath, "wb");
    if (out == NULL) {
        fclose(in);
        pack_fail(err, errLen, "cannot open output for writing");
        return 2;
    }
    unsigned char buf[PACK_GZIP_CHUNK];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) {
        if (gzwrite(out, buf, (unsigned int)n) != (int)n) {
            int zerr = Z_OK;
            const char *zmsg = gzerror(out, &zerr);
            fclose(in);
            gzclose(out);
            pack_fail(err, errLen, zmsg);
            return 2;
        }
    }
    fclose(in);
    if (gzclose(out) != Z_OK) {
        pack_fail(err, errLen, "close failed (disk full?)");
        return 2;
    }
    return 0;
}
