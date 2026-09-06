<?php
// Kein composer.json und keine Server-Konfiguration im Quellbaum: damit greift
// Order-Gruppe 3 des php-Composites (php-dist, composer*, composer-install*,
// php-builtin-server, ...) - der Pfad ueber "php -S" ohne httpd oder nginx.
// Die Gruppen 1 und 2 verlangen httpd bzw. nginx als nicht-optionales Mitglied,
// und deren Detect braucht eine httpd.conf/nginx.conf oder BP_WEB_SERVER.
// JSON_UNESCAPED_SLASHES ist nicht Kosmetik: json_encode escapt Slashes per
// Default, aus "paketo-buildpacks/php" wird dann "paketo-buildpacks\/php" - und
// der Smoke-Test sucht genau diese Zeichenkette. Ohne das Flag ist die App
// fehlerfrei und der Test trotzdem rot.
header('Content-Type: application/json');

$pfad = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);

if ($pfad === '/env') {
    echo json_encode(['vcap_services' => getenv('VCAP_SERVICES') ?: '<leer>'], JSON_UNESCAPED_SLASHES);
    return;
}

echo json_encode([
    'message'               => 'Hallo von PHP auf Korifi',
    'buildpack'             => 'paketo-buildpacks/php',
    'vcap_services_present' => (bool) getenv('VCAP_SERVICES'),
], JSON_UNESCAPED_SLASHES);
