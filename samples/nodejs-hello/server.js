// Absichtlich ohne Abhängigkeiten: der Smoke-Test soll das Buildpack prüfen,
// nicht die Erreichbarkeit von npmjs.org. node-engine und npm-install laufen
// trotzdem, das belegt der buildMetadata-Check in smoke/buildpacks.sh.
const http = require("http");

const body = JSON.stringify({
  message: "Hallo von Node.js auf Korifi",
  buildpack: "paketo-buildpacks/nodejs",
  vcap_services_present: Boolean(process.env.VCAP_SERVICES),
});

http
  .createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(req.url === "/env" ? JSON.stringify({ vcap_services: process.env.VCAP_SERVICES || "<leer>" }) : body);
  })
  // PORT setzt Korifi im AppWorkload. Der Fallback ist nur für den lokalen Lauf.
  .listen(process.env.PORT || 8080, () => console.log("listening"));
