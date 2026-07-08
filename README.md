# cicd-demo

A minimal .NET web API used as a reference implementation for a production-grade CI/CD pipeline: GitHub Actions, environment promotion (dev → stg → prod), build-once-promote-many artifacts, and blue/green deploys to Azure App Service.

See [docs/operations-manual.md](docs/operations-manual.md) for how to build, release, roll back, and troubleshoot, and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the C4 architecture documentation.

Shipped versions are listed on the [Releases page](https://github.com/pixelbits-mk/cicd-demo/releases); every stg/prod deploy is also tagged `build/<env>/<label>`.
