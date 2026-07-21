# Runtime-only image: CI compiles and tests the app (dotnet publish in
# _build.yml), then az acr build packages the published output as-is — the
# bytes that were tested are the bytes that ship (_image.yml supplies
# ./publish as the build context alongside this file). There is no SDK
# stage on purpose: building from source here would rebuild, breaking the
# tested-bytes guarantee.
#
# The port must match the Container App's ingress target_port (8080, set
# by the infrastructure repo's cicd-demo module).
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY publish/ .
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "Api.dll"]
