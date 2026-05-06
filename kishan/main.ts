import { NestFactory } from "@nestjs/core"
import * as dotenv from "dotenv"
import { loadSecrets } from "./common/config/secret-manager"
console.log(process.env.NODE_ENV)
const envFilePath = process.env.NODE_ENV == "production" ? ".env" : `.env.${process.env.NODE_ENV || "development"}`
console.log(envFilePath)
dotenv.config({ path: envFilePath })
import { AppModule } from "./app.module"
import { Logger, VersioningType } from "@nestjs/common"
import { DocumentBuilder, SwaggerModule } from "@nestjs/swagger"
import { ValidationPipe } from "./validation-pipe/validation.pipe"
import * as bodyParser from "body-parser"

async function bootstrap() {
    await loadSecrets()
    const app = await NestFactory.create(AppModule)
    // Get the underlying express instance
    const expressApp = app.getHttpAdapter().getInstance()

    // Enable trust proxy
    expressApp.set("trust proxy", 1)

    expressApp.get("/", (req, res) => {
        res.status(200).json({ message: "CPMS API is running..." })
    })

    app.enableVersioning({
        defaultVersion: "1",
        type: VersioningType.URI
    })

    app.enableCors()
    app.useGlobalPipes(new ValidationPipe())
    app.use(bodyParser.urlencoded({ extended: true }))
    app.use(bodyParser.json({ limit: "50mb" }))

    if (process.env.NODE_ENV !== "production") {
        //initializeSwagger(app)
    }

    // const seederService = app.get(SeederService);
    // console.log(seederService);
    // await seederService.seedUsers();
    const server = await app.listen(process.env.PORT, "0.0.0.0")
    Logger.debug(`🚀  Server is listening on port ${process.env.PORT}`)
}

function initializeSwagger(app) {
    const config = new DocumentBuilder()
        .addBearerAuth(
            {
                type: "http",
                scheme: "Bearer",
                bearerFormat: "JWT",
                in: "header"
            },
            "access-token"
        )
        .setTitle("CPMS API")
        .setDescription("CPMS API 🚀")
        .setVersion("v1")
        .build()

    const document = SwaggerModule.createDocument(app, config)
    SwaggerModule.setup("api-docs", app, document)
}

bootstrap().catch((e) => {
    Logger.error(`❌  Error starting server, ${e}`)
    throw e
})
