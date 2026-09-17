FROM public.ecr.aws/sam/build-dotnet10:latest-arm64

ARG DOTNET_SDK_VERSION

RUN test -n "$DOTNET_SDK_VERSION" \
    && curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK_VERSION}/dotnet-sdk-${DOTNET_SDK_VERSION}-linux-arm64.tar.gz" \
    | tar -xz -C /var/lang/bin

ENV DOTNET_ROOT=/var/lang/bin \
    PATH=/var/lang/bin:${PATH}
