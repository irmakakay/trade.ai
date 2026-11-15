# Stage 1: Build React + TradingView Canvas UI
FROM node:20-alpine AS ui-build
WORKDIR /ui
COPY src/quant-ui/package.json ./
RUN npm install
COPY src/quant-ui/ ./
RUN npm run build

# Stage 2: Build .NET 8 Minimal API
FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS net-build
WORKDIR /src
COPY QuantCore.sln ./
COPY src/QuantCore.Contracts/QuantCore.Contracts.csproj src/QuantCore.Contracts/
COPY src/QuantCore.Api/QuantCore.Api.csproj src/QuantCore.Api/
RUN dotnet restore src/QuantCore.Api/QuantCore.Api.csproj
COPY src/QuantCore.Contracts/ src/QuantCore.Contracts/
COPY src/QuantCore.Api/ src/QuantCore.Api/
RUN dotnet publish src/QuantCore.Api/QuantCore.Api.csproj -c Release -o /app/publish

# Stage 3: Ultra-Light Alpine Runtime
FROM mcr.microsoft.com/dotnet/aspnet:8.0-alpine
WORKDIR /app
COPY --from=net-build /app/publish .
COPY --from=ui-build /ui/dist ./wwwroot
EXPOSE 8080
ENTRYPOINT ["dotnet", "QuantCore.Api.dll"]
