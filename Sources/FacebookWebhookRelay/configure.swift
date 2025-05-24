import Vapor

public func configure(_ app: Application) async throws {
    // Increase body collection limit if you expect large payloads,
    // though Facebook webhooks are usually small. Default is 16KB.
    app.routes.defaultMaxBodySize = "10mb"


    // Configure CORS
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all, // Be more specific in production if possible
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [
            .accept,
            .authorization,
            .contentType,
            .origin,
            HTTPHeaders.Name("X-Requested-With"), // Corrected
            .userAgent,
            .accessControlAllowOrigin,
            HTTPHeaders.Name("X-Hub-Signature-256"), // Corrected
            .cacheControl
        ]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    // IMPORTANT: Add CORS middleware before routes
    app.middleware.use(cors, at: .beginning)
    
    // Serve files from /Public directory if you have any (not needed for this webhook)
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // Register routes
    try routes(app)

    // Set port from environment or default
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "8080") ?? 8080
}
