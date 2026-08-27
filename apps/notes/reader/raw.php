<?php
// Serve only renderer-supported attachments through the vault-specific FPM
// process. The router never mounts a vault, so this is the sole byte path.
const TYPES = [
    'png' => 'image/png', 'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif', 'bmp' => 'image/bmp', 'tif' => 'image/tiff',
    'tiff' => 'image/tiff', 'webp' => 'image/webp', 'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf', 'mp4' => 'video/mp4', 'm4a' => 'audio/mp4',
];

$uri = $_SERVER['REQUEST_URI'] ?? '';
$path = parse_url($uri, PHP_URL_PATH);
if (!is_string($path) || strncmp($path, '/notes/', 7) !== 0) {
    http_response_code(400);
    exit;
}
$relative = rawurldecode(substr($path, 7));
if ($relative === '' || strpos($relative, "\0") !== false) {
    http_response_code(400);
    exit;
}
foreach (explode('/', $relative) as $segment) {
    if ($segment === '' || $segment[0] === '.') {
        http_response_code(403);
        exit;
    }
}
$extension = strtolower(pathinfo($relative, PATHINFO_EXTENSION));
if (!array_key_exists($extension, TYPES)) {
    http_response_code(403);
    exit;
}
$base = realpath('/var/www/perlite/notes');
$file = $base === false ? false : realpath($base . '/' . $relative);
if ($file === false || strncmp($file, $base . '/', strlen($base) + 1) !== 0 || !is_file($file)) {
    http_response_code(404);
    exit;
}
$type = TYPES[$extension];
header('Content-Type: ' . $type);
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
if ($type === 'image/svg+xml') {
    header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; sandbox");
}
header('Content-Length: ' . (string) filesize($file));
readfile($file);
