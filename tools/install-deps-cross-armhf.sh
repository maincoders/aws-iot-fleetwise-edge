#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR=$(dirname $(realpath "$0"))
source ${SCRIPT_DIR}/install-deps-versions.sh

USE_CACHE="true"
WITH_GREENGRASSV2_SUPPORT="false"
SHARED_LIBS="OFF"

parse_args() {
    while [ "$#" -gt 0 ]; do
        case $1 in
        --with-greengrassv2-support)
            WITH_GREENGRASSV2_SUPPORT="true"
            ;;
        --native-prefix)
            NATIVE_PREFIX="$2"
            USE_CACHE="false"
            shift
            ;;
        --shared-libs)
            SHARED_LIBS="ON"
            ;;
        --help)
            echo "Usage: $0 [OPTION]"
            echo "  --with-greengrassv2-support  Install dependencies for Greengrass V2"
            echo "  --native-prefix              Native install prefix"
            echo "  --shared-libs                Build shared libs, rather than static libs"
            exit 0
            ;;
        esac
        shift
    done
}

parse_args "$@"

ARCH=`dpkg --print-architecture`
if [ "${ARCH}" == "armhf" ]; then
    echo "Error: Architecture is already ${ARCH}, use install-deps-native.sh" >&2
    exit -1
fi

print_file() {
    echo ">>> $1: $2"
    cat $2
    echo ">>>"
}

print_file "Before patching" /etc/apt/sources.list
sed -i -E "s/deb (http|mirror\+file)/deb [arch=${ARCH}] \1/g" /etc/apt/sources.list
cp /etc/apt/sources.list /etc/apt/sources.list.d/armhf.list
sed -i -E "s/deb \[arch=${ARCH}\] (http|mirror\+file)/deb [arch=armhf] \1/g" /etc/apt/sources.list.d/armhf.list
# GitHub uses a separate mirrors file
if [ -f /etc/apt/apt-mirrors.txt ]; then
    print_file "Before patching" /etc/apt/apt-mirrors.txt
    cp /etc/apt/apt-mirrors.txt /etc/apt/apt-mirrors-armhf.txt
    sed -i "s#/etc/apt/apt-mirrors.txt#/etc/apt/apt-mirrors-armhf.txt#g" /etc/apt/sources.list.d/armhf.list
    PATCH_FILE="/etc/apt/apt-mirrors-armhf.txt"
    print_file "After patching" /etc/apt/apt-mirrors-armhf.txt
else
    PATCH_FILE="/etc/apt/sources.list.d/armhf.list"
fi
sed -i -E "s#(archive|security).ubuntu.com/ubuntu#ports.ubuntu.com/ubuntu-ports#g" ${PATCH_FILE}
print_file "After patching" /etc/apt/sources.list.d/armhf.list

dpkg --add-architecture armhf
apt update
apt install -y \
    build-essential \
    cmake \
    crossbuild-essential-armhf \
    curl \
    git \
    libboost-log-dev:armhf \
    libboost-system-dev:armhf \
    libboost-thread-dev:armhf \
    libsnappy-dev:armhf \
    libssl-dev:armhf \
    unzip \
    wget \
    zlib1g-dev:armhf

if [ ! -f /usr/include/linux/can/isotp.h ]; then
    git clone https://github.com/hartkopp/can-isotp.git
    cd can-isotp
    git checkout beb4650660179963a8ed5b5cbf2085cc1b34f608
    cp include/uapi/linux/can/isotp.h /usr/include/linux/can
    cd ..
    rm -rf can-isotp
fi

if [ -z "${NATIVE_PREFIX+x}" ]; then
    NATIVE_PREFIX="/usr/local/`gcc -dumpmachine`"
fi

if ! ${USE_CACHE} || [ ! -d /usr/local/arm-linux-gnueabihf ] || [ ! -d ${NATIVE_PREFIX} ]; then
    mkdir -p /usr/local/arm-linux-gnueabihf/lib/cmake/
    mkdir -p ${NATIVE_PREFIX}
    cp ${SCRIPT_DIR}/armhf-toolchain.cmake /usr/local/arm-linux-gnueabihf/lib/cmake/
    mkdir deps-cross-armhf && cd deps-cross-armhf

    git clone -b ${VERSION_JSON_CPP} https://github.com/open-source-parsers/jsoncpp.git
    cd jsoncpp
    mkdir build && cd build
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=${SHARED_LIBS} \
        -DCMAKE_POSITION_INDEPENDENT_CODE=On \
        -DJSONCPP_WITH_TESTS=Off \
        -DJSONCPP_WITH_POST_BUILD_UNITTEST=Off \
        -DCMAKE_TOOLCHAIN_FILE=/usr/local/arm-linux-gnueabihf/lib/cmake/armhf-toolchain.cmake \
        -DCMAKE_INSTALL_PREFIX=/usr/local/arm-linux-gnueabihf \
        ..
    make install -j`nproc`
    cd ../..

    wget -q https://github.com/protocolbuffers/protobuf/releases/download/${VERSION_PROTOBUF_RELEASE}/protobuf-cpp-${VERSION_PROTOBUF}.tar.gz
    tar -zxf protobuf-cpp-${VERSION_PROTOBUF}.tar.gz
    cd protobuf-${VERSION_PROTOBUF}
    mkdir build && cd build
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=${SHARED_LIBS} \
        -DCMAKE_POSITION_INDEPENDENT_CODE=On \
        -Dprotobuf_BUILD_TESTS=Off \
        -DCMAKE_INSTALL_PREFIX=${NATIVE_PREFIX} \
        ..
    make install -j`nproc`
    cd ..
    mkdir build_armhf && cd build_armhf
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=${SHARED_LIBS} \
        -DCMAKE_POSITION_INDEPENDENT_CODE=On \
        -Dprotobuf_BUILD_TESTS=Off \
        -Dprotobuf_BUILD_PROTOC_BINARIES=Off \
        -DCMAKE_TOOLCHAIN_FILE=/usr/local/arm-linux-gnueabihf/lib/cmake/armhf-toolchain.cmake \
        -DCMAKE_INSTALL_PREFIX=/usr/local/arm-linux-gnueabihf \
        ..
    make install -j`nproc`
    cd ../..

    wget -q https://github.com/curl/curl/releases/download/${VERSION_CURL_RELEASE}/curl-${VERSION_CURL}.tar.gz
    tar -zxf curl-${VERSION_CURL}.tar.gz
    cd curl-${VERSION_CURL}
    mkdir build && cd build
    CURL_OPTIONS="
        --disable-ldap
        --enable-ipv6
        --with-ssl
        --disable-unix-sockets
        --disable-rtsp
        --without-zstd
        --host=arm-linux
        --prefix=/usr/local/arm-linux-gnueabihf"
    if [ "${SHARED_LIBS}" == "OFF" ]; then
        LDFLAGS="-static" PKG_CONFIG="pkg-config --static" CC=arm-linux-gnueabihf-gcc \
        ../configure \
            --disable-shared \
            --enable-static \
            ${CURL_OPTIONS}
        make install -j`nproc` V=1 LDFLAGS="-static"
    else
        CC=arm-linux-gnueabihf-gcc \
        ../configure \
            --enable-shared \
            --disable-static \
            ${CURL_OPTIONS}
        make install -j`nproc` V=1
    fi
    cd ../..

    # Build AWS IoT Device SDK before AWS SDK because they both include aws-crt-cpp as submodules.
    # And although we make sure both versions match, we want the AWS SDK version to prevail so that
    # we always use the same aws-crt-cpp regardless whether Greengrass is enabled.
    if ${WITH_GREENGRASSV2_SUPPORT}; then
        git clone -b ${VERSION_AWS_IOT_DEVICE_SDK_CPP_V2} --recursive https://github.com/aws/aws-iot-device-sdk-cpp-v2.git
        cd aws-iot-device-sdk-cpp-v2
        mkdir build && cd build
        cmake \
            -DBUILD_SHARED_LIBS=${SHARED_LIBS} \
            -DBUILD_DEPS=ON \
            -DBUILD_TESTING=OFF \
            -DUSE_OPENSSL=ON \
            -DBUILD_ONLY='greengrass_ipc' \
            -DCMAKE_TOOLCHAIN_FILE=/usr/local/arm-linux-gnueabihf/lib/cmake/armhf-toolchain.cmake \
            -DCMAKE_INSTALL_PREFIX=/usr/local/arm-linux-gnueabihf \
            ..
        make install -j`nproc`
        cd ../..
    fi

    git clone -b ${VERSION_AWS_SDK_CPP} --recursive https://github.com/aws/aws-sdk-cpp.git
    cd aws-sdk-cpp
    mkdir build && cd build
    if [ "${SHARED_LIBS}" == "OFF" ]; then
        AWS_SDK_CPP_OPTIONS="-DZLIB_LIBRARY=/usr/lib/arm-linux-gnueabihf/libz.a -DCURL_LIBRARY=/usr/local/arm-linux-gnueabihf/lib/libcurl.a"
    else
        AWS_SDK_CPP_OPTIONS=""
    fi
    cmake \
        -DENABLE_TESTING=OFF \
        -DBUILD_SHARED_LIBS=${SHARED_LIBS} \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_ONLY='s3-crt;iot' \
        -DAWS_CUSTOM_MEMORY_MANAGEMENT=ON \
        ${AWS_SDK_CPP_OPTIONS} \
        -DCMAKE_TOOLCHAIN_FILE=/usr/local/arm-linux-gnueabihf/lib/cmake/armhf-toolchain.cmake \
        -DCMAKE_INSTALL_PREFIX=/usr/local/arm-linux-gnueabihf \
        ..
    make install -j`nproc`
    cd ../..

    cd ..
    rm -rf deps-cross-armhf
fi
