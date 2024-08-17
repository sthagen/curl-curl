#***************************************************************************
#                                  _   _ ____  _
#  Project                     ___| | | |  _ \| |
#                             / __| | | | |_) | |
#                            | (__| |_| |  _ <| |___
#                             \___|\___/|_| \_\_____|
#
# Copyright (C) Daniel Stenberg, <daniel@haxx.se>, et al.
#
# This software is licensed as described in the file COPYING, which
# you should have received as part of this distribution. The terms
# are also available at https://curl.se/docs/copyright.html.
#
# You may opt to use, copy, modify, merge, publish, distribute and/or sell
# copies of the Software, and permit persons to whom the Software is
# furnished to do so, under the terms of the COPYING file.
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
# KIND, either express or implied.
#
# SPDX-License-Identifier: curl
#
###########################################################################
# Find the wolfssl library
#
# Result Variables:
#
# WolfSSL_FOUND         System has wolfssl
# WolfSSL_INCLUDE_DIRS  The wolfssl include directories
# WolfSSL_LIBRARIES     The wolfssl library names
# WolfSSL_VERSION       Version of wolfssl

if(CURL_USE_PKGCONFIG)
  find_package(PkgConfig QUIET)
  pkg_check_modules(PC_WOLFSSL QUIET "wolfssl")
endif()

find_path(WolfSSL_INCLUDE_DIR NAMES "wolfssl/ssl.h"
  HINTS
    ${PC_WOLFSSL_INCLUDEDIR}
    ${PC_WOLFSSL_INCLUDE_DIRS}
)

find_library(WolfSSL_LIBRARY NAMES "wolfssl"
  HINTS
    ${PC_WOLFSSL_LIBDIR}
    ${PC_WOLFSSL_LIBRARY_DIRS}
)

if(PC_WOLFSSL_VERSION)
  set(WolfSSL_VERSION ${PC_WOLFSSL_VERSION})
elseif(WolfSSL_INCLUDE_DIR)
  set(_version_regex "^#define[ \t]+LIBWOLFSSL_VERSION_STRING[ \t]+\"([^\"]+)\".*")
  file(STRINGS "${WolfSSL_INCLUDE_DIR}/wolfssl/version.h" WolfSSL_VERSION REGEX "${_version_regex}")
  string(REGEX REPLACE "${_version_regex}" "\\1" WolfSSL_VERSION "${WolfSSL_VERSION}")
  unset(_version_regex)
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(WolfSSL
  REQUIRED_VARS
    WolfSSL_INCLUDE_DIR
    WolfSSL_LIBRARY
  VERSION_VAR
    WolfSSL_VERSION
)

if(WolfSSL_FOUND)
  set(WolfSSL_INCLUDE_DIRS ${WolfSSL_INCLUDE_DIR})
  set(WolfSSL_LIBRARIES    ${WolfSSL_LIBRARY})
endif()

mark_as_advanced(WolfSSL_INCLUDE_DIR WolfSSL_LIBRARY)
