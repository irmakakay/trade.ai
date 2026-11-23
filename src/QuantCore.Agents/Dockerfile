FROM mcr.microsoft.com/dotnet/sdk:9.0-alpine AS build
WORKDIR /src
COPY src/QuantCore.Contracts/QuantCore.Contracts.csproj src/QuantCore.Contracts/
COPY src/QuantCore.Agents/QuantCore.Agents.csproj src/QuantCore.Agents/
RUN dotnet restore src/QuantCore.Agents/QuantCore.Agents.csproj
COPY src/QuantCore.Contracts/ src/QuantCore.Contracts/
COPY src/QuantCore.Agents/ src/QuantCore.Agents/
RUN dotnet publish src/QuantCore.Agents/QuantCore.Agents.csproj -c Release -o /app/publish

FROM mcr.microsoft.com/dotnet/runtime:9.0-alpine
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "QuantCore.Agents.dll"]
CMD ["--mode", "agent"]
