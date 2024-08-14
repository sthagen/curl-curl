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
# Find the nghttp2 library
#
# Result Variables:
#
# NGHTTP2_FOUND         System has nghttp2
# NGHTTP2_INCLUDE_DIRS  The nghttp2 include directories
# NGHTTP2_LIBRARIES     The nghttp2 library names
# NGHTTP2_VERSION       Version of nghttp2

if(CURL_USE_PKGCONFIG)
  find_package(PkgConfig QUIET)
  pkg_search_module(PC_NGHTTP2 "libnghttp2")
endif()

find_path(NGHTTP2_INCLUDE_DIR "nghttp2/nghttp2.h"
  HINTS
    ${PC_NGHTTP2_INCLUDEDIR}
    ${PC_NGHTTP2_INCLUDE_DIRS}
)

find_library(NGHTTP2_LIBRARY NAMES "nghttp2" "nghttp2_static"
  HINTS
    ${PC_NGHTTP2_LIBDIR}
    ${PC_NGHTTP2_LIBRARY_DIRS}
)

if(PC_NGHTTP2_VERSION)
  set(NGHTTP2_VERSION ${PC_NGHTTP2_VERSION})
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(NGHTTP2
  FOUND_VAR
    NGHTTP2_FOUND
  REQUIRED_VARS
    NGHTTP2_INCLUDE_DIR
    NGHTTP2_LIBRARY
  VERSION_VAR
    NGHTTP2_VERSION
)

if(NGHTTP2_FOUND)
  set(NGHTTP2_INCLUDE_DIRS ${NGHTTP2_INCLUDE_DIR})
  set(NGHTTP2_LIBRARIES    ${NGHTTP2_LIBRARY})
endif()

mark_as_advanced(NGHTTP2_INCLUDE_DIRS NGHTTP2_LIBRARIES)
