# Global build arguments (available in all stages)
ARG IMAGE_TYPE=extras
ARG BASE_IMAGE=ubuntu:22.04
ARG GRPC_BASE_IMAGE=${BASE_IMAGE}
ARG INTEL_BASE_IMAGE=${BASE_IMAGE}
ARG GO_VERSION=1.22.6
ARG TARGETARCH
ARG TARGETVARIANT
ARG CUDA_MAJOR_VERSION=12
ARG CUDA_MINOR_VERSION=2    # Updated CUDA minor version
ARG BUILD_TYPE=cublas

# The requirements-core target is common to all images.
FROM ${BASE_IMAGE} AS requirements-core

# Build arguments (available in this stage)
ARG GO_VERSION
ARG TARGETARCH

USER root

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV EXTERNAL_GRPC_BACKENDS="transformers:/build/backend/python/transformers/run.sh,sentencetransformers:/build/backend/python/sentencetransformers/run.sh"
ENV PATH=$PATH:/root/go/bin:/usr/local/go/bin

# Install core dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        ca-certificates \
        cmake \
        curl \
        git \
        unzip \
        upx-ucl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Go
RUN curl -L -s https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH:-amd64}.tar.gz | tar -C /usr/local -xz

# Install GRPC tools
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# Install protoc based on architecture
RUN if [ "${TARGETARCH}" = "amd64" ] || [ "${TARGETARCH}" = "" ]; then \
        curl -L -s https://github.com/protocolbuffers/protobuf/releases/download/v27.1/protoc-27.1-linux-x86_64.zip -o protoc.zip && \
        unzip -j -d /usr/local/bin protoc.zip bin/protoc && \
        rm protoc.zip; \
    elif [ "${TARGETARCH}" = "arm64" ]; then \
        curl -L -s https://github.com/protocolbuffers/protobuf/releases/download/v27.1/protoc-27.1-linux-aarch_64.zip -o protoc.zip && \
        unzip -j -d /usr/local/bin protoc.zip bin/protoc && \
        rm protoc.zip; \
    else \
        echo "Unsupported TARGETARCH: ${TARGETARCH}"; \
        exit 1; \
    fi

# Add CUDA and ROCm to PATH
ENV PATH=/usr/local/cuda/bin:/opt/rocm/bin:${PATH}

WORKDIR /build

###################################

# The builder stage
FROM requirements-core AS builder

# Build arguments
ARG TARGETARCH
ARG CUDA_MAJOR_VERSION
ARG CUDA_MINOR_VERSION
ARG BUILD_TYPE

# Set environment variables
ENV TARGETARCH=${TARGETARCH}
ENV CUDA_MAJOR_VERSION=${CUDA_MAJOR_VERSION}
ENV CUDA_MINOR_VERSION=${CUDA_MINOR_VERSION}
ENV BUILD_TYPE=${BUILD_TYPE}

# Install CUDA components necessary for cublas
RUN set -ex; \
    if [ "${BUILD_TYPE}" = "cublas" ]; then \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            wget \
            gnupg2 \
            ca-certificates; \
        wget -qO /tmp/cuda-keyring.deb "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb"; \
        dpkg -i /tmp/cuda-keyring.deb; \
        rm /tmp/cuda-keyring.deb; \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            cuda-toolkit-${CUDA_MAJOR_VERSION}-${CUDA_MINOR_VERSION}; \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Set CUDA environment variables
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_REQUIRE_CUDA="cuda>=${CUDA_MAJOR_VERSION}.0"
ENV NVIDIA_VISIBLE_DEVICES=all

# Copy source code
WORKDIR /build
COPY . .

# Prepare sources
RUN make prepare

# Build the application with the 'build-pfe' target
RUN make build-pfe

###################################

# Final image
FROM ubuntu:22.04

# Build arguments
ARG CUDA_MAJOR_VERSION
ARG BUILD_TYPE

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV BUILD_TYPE=${BUILD_TYPE}
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_REQUIRE_CUDA="cuda>=${CUDA_MAJOR_VERSION}.0"
ENV NVIDIA_VISIBLE_DEVICES=all

# Install minimal runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl && \
    rm -rf /var/lib/apt/lists/*

# Copy the application binary
COPY --from=builder /build/local-ai /app/local-ai

# Set working directory
WORKDIR /app

# Expose necessary ports
EXPOSE 8080

# Set entrypoint
ENTRYPOINT ["/app/local-ai"]
