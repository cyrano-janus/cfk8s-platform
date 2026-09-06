package hello;

import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

public class App {

    private static final String BODY = """
            {"message":"Hallo von Java auf Korifi",\
            "buildpack":"paketo-buildpacks/java",\
            "vcap_services_present":%s}""";

    public static void main(String[] args) throws IOException {
        // PORT setzt Korifi im AppWorkload; der Fallback ist nur fuer lokale Laeufe.
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
        String vcap = System.getenv("VCAP_SERVICES");
        String body = BODY.formatted(vcap != null && !vcap.isEmpty());

        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/", exchange -> respond(exchange, body));
        server.createContext("/env", exchange -> respond(exchange,
                "{\"vcap_services\":%s}".formatted(
                        vcap == null ? "\"<leer>\"" : "\"" + vcap.replace("\"", "\\\"") + "\"")));
        server.start();
        System.out.println("listening on " + port);
    }

    private static void respond(com.sun.net.httpserver.HttpExchange exchange, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }
}
