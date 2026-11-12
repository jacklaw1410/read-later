#pragma once

#include <stddef.h>

/// Stream `srcPath` (.gz) to `dstPath`. Returns 0 on success, nonzero on
/// failure with a message in `err` (up to `errLen` bytes, always NUL-ended).
int pack_gunzip(const char *srcPath, const char *dstPath, char *err, size_t errLen);

/// Stream `srcPath` (raw bytes) to `dstPath` (.gz). Same contract.
int pack_gzip(const char *srcPath, const char *dstPath, char *err, size_t errLen);
