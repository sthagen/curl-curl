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
# Find the bearssl library
#
# Result Variables:
#
# BEARSSL_FOUND         System has bearssl
# BEARSSL_INCLUDE_DIRS  The bearssl include directories
# BEARSSL_LIBRARIES     The bearssl library names

# for compatibility. Configuration via BEARSSL_INCLUDE_DIRS is deprecated, use BEARSSL_INCLUDE_DIR instead.
if(DEFINED BEARSSL_INCLUDE_DIRS AND NOT DEFINED BEARSSL_INCLUDE_DIR)
  set(BEARSSL_INCLUDE_DIR "${BEARSSL_INCLUDE_DIRS}")
  unset(BEARSSL_INCLUDE_DIRS)
endif()

find_path(BEARSSL_INCLUDE_DIR "bearssl.h")
find_library(BEARSSL_LIBRARY "bearssl")

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(BEARSSL
  REQUIRED_VARS
    BEARSSL_INCLUDE_DIR
    BEARSSL_LIBRARY
)

if(BEARSSL_FOUND)
  set(BEARSSL_INCLUDE_DIRS ${BEARSSL_INCLUDE_DIR})
  set(BEARSSL_LIBRARIES    ${BEARSSL_LIBRARY})
endif()

mark_as_advanced(BEARSSL_INCLUDE_DIR BEARSSL_LIBRARY)
