#ifndef NEWT_SYSTEMCHECK_H
#define NEWT_SYSTEMCHECK_H
// SPDX-License-Identifier: MIT
#include <cctype>

inline bool IsSimulatedSystemName(const char* name) {
    if (!name) return false;
    const char* needle = "simulat";
    for (const char* p = name; *p; ++p) {
        size_t i = 0;
        while (needle[i] && p[i] &&
               std::tolower(static_cast<unsigned char>(p[i])) == needle[i]) ++i;
        if (!needle[i]) return true;
    }
    return false;
}

#endif // NEWT_SYSTEMCHECK_H
