<?php
/**
 * Koken web installer (PHP 8.1+, tested with PHP 8.5)
 *
 * Sets up a fresh Koken installation:
 *   1. checks the server requirements (PHP, extensions, write permissions, loopback HTTP)
 *   2. asks for the database (or uses the one provided by Docker via KOKEN_DB_* env vars)
 *   3. asks for the administrator account
 *   4. creates storage/, installs the default theme and runs Koken's own
 *      install routine (api.php?/install/complete)
 *
 * When the environment variable KOKEN_INSTALL_TOKEN is set (setup.sh does this),
 * the installer can only be used with that token, so nobody else can take over
 * a freshly deployed site.
 */

declare(strict_types=1);

const KOKEN_MIN_PHP = '8.1.0';

error_reporting(E_ALL);
ini_set('display_errors', '0');
date_default_timezone_set('UTC');

$ROOT = dirname(__DIR__);
$STORAGE = $ROOT . '/storage';
$DEFAULTS = __DIR__ . '/defaults';

session_name('koken_installer');
session_start();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function h($value): string
{
	return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function env(string $name, string $default = ''): string
{
	$value = getenv($name);
	return $value === false ? $default : $value;
}

/** Base path of the Koken installation, e.g. "" or "/photos" */
function base_path(): string
{
	$base = rtrim(str_replace('\\', '/', dirname(dirname($_SERVER['SCRIPT_NAME']))), '/');
	return $base === '.' ? '' : $base;
}

function is_https(): bool
{
	return (!empty($_SERVER['HTTPS']) && strtolower($_SERVER['HTTPS']) !== 'off')
		|| (isset($_SERVER['SERVER_PORT']) && (int) $_SERVER['SERVER_PORT'] === 443)
		|| (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https');
}

function site_url(string $path = '/'): string
{
	return (is_https() ? 'https' : 'http') . '://' . $_SERVER['HTTP_HOST'] . base_path() . $path;
}

/**
 * HTTP request from the server to itself – exactly the way Koken does it.
 * $host_header = false: connect to HTTP_HOST (Koken default)
 * $host_header = true:  connect to SERVER_ADDR:SERVER_PORT and send the Host
 *                       header (Koken's LOOPBACK_HOST_HEADER, needed behind
 *                       Docker port mappings, proxies, ...)
 */
function loopback(bool $host_header, string $path, ?array $post = null, int $timeout = 10): array
{
	$protocol = is_https() ? 'https' : 'http';
	$headers = [];

	if ($host_header) {
		$host = $_SERVER['SERVER_ADDR'] . ':' . $_SERVER['SERVER_PORT'];
		$headers[] = 'Host: ' . $_SERVER['HTTP_HOST'];
	} else {
		$host = $_SERVER['HTTP_HOST'];
	}

	$curl = curl_init($protocol . '://' . $host . base_path() . $path);
	curl_setopt_array($curl, [
		CURLOPT_RETURNTRANSFER => true,
		CURLOPT_CONNECTTIMEOUT => 5,
		CURLOPT_TIMEOUT => $timeout,
		CURLOPT_HTTPHEADER => $headers,
		CURLOPT_SSL_VERIFYPEER => false,
		CURLOPT_SSL_VERIFYHOST => 0,
	]);

	if ($post !== null) {
		curl_setopt($curl, CURLOPT_POST, true);
		curl_setopt($curl, CURLOPT_POSTFIELDS, http_build_query($post, '', '&'));
	}

	$body = curl_exec($curl);
	$code = (int) curl_getinfo($curl, CURLINFO_HTTP_CODE);
	$error = curl_error($curl);

	return ['code' => $code, 'body' => is_string($body) ? $body : '', 'error' => $error];
}

/** Which loopback variant works on this server? null = none */
function detect_loopback(): ?bool
{
	foreach ([false, true] as $host_header) {
		$r = loopback($host_header, '/install/index.php?ping=1', null, 5);
		if ($r['code'] === 200 && trim($r['body']) === 'koken-installer-pong') {
			return $host_header;
		}
	}
	return null;
}

function db_connect(array $db, ?string &$error = null): ?mysqli
{
	mysqli_report(MYSQLI_REPORT_OFF);
	$host = $db['hostname'];
	$port = null;
	$socket = null;

	if (str_contains($host, ':')) {
		[$host, $extra] = explode(':', $host, 2);
		if (ctype_digit($extra)) {
			$port = (int) $extra;
		} else {
			$socket = $extra;
		}
	}

	$link = @mysqli_connect($host, $db['username'], $db['password'], $db['database'], $port, $socket);
	if (!$link) {
		$error = mysqli_connect_error() ?: 'Unknown error';
		return null;
	}
	return $link;
}

/** Number of Koken users in the database, null if the table does not exist */
function koken_user_count(mysqli $link, string $prefix): ?int
{
	$table = $prefix . 'users';
	$res = mysqli_query($link, "SHOW TABLES LIKE '" . mysqli_real_escape_string($link, $table) . "'");
	if (!$res || mysqli_num_rows($res) === 0) {
		return null;
	}
	$res = mysqli_query($link, 'SELECT COUNT(*) FROM `' . str_replace('`', '', $table) . '`');
	return $res ? (int) mysqli_fetch_row($res)[0] : 0;
}

function stored_db_config(string $storage): ?array
{
	$file = $storage . '/configuration/database.php';
	if (!is_file($file)) {
		return null;
	}
	$config = include $file;
	if (isset($KOKEN_DATABASE)) {
		$config = $KOKEN_DATABASE;
	}
	return is_array($config) ? $config : [];
}

/** Same rule as the install controller: an existing config means "installed"
 *  unless its database is reachable and has no Koken users. */
function is_installed(string $storage): bool
{
	$config = stored_db_config($storage);
	if ($config === null) {
		return false;
	}
	if (empty($config['hostname'])) {
		return false;
	}
	$link = db_connect($config + ['username' => '', 'password' => '', 'database' => '']);
	if (!$link) {
		return true;
	}
	$count = koken_user_count($link, $config['prefix'] ?? '');
	return $count !== null && $count > 0;
}

function docker_db(): ?array
{
	if (env('KOKEN_DB_HOST') === '' || env('KOKEN_DB_NAME') === '') {
		return null;
	}
	return [
		'hostname' => env('KOKEN_DB_HOST'),
		'database' => env('KOKEN_DB_NAME'),
		'username' => env('KOKEN_DB_USER'),
		'password' => env('KOKEN_DB_PASSWORD'),
		'prefix' => env('KOKEN_DB_PREFIX', 'koken_'),
	];
}

function writable_dir(string $dir): bool
{
	if (!is_dir($dir)) {
		return is_writable(dirname($dir));
	}
	return is_writable($dir);
}

function copy_tree(string $from, string $to): void
{
	if (!is_dir($to)) {
		mkdir($to, 0755, true);
	}
	$items = new RecursiveIteratorIterator(
		new RecursiveDirectoryIterator($from, FilesystemIterator::SKIP_DOTS),
		RecursiveIteratorIterator::SELF_FIRST
	);
	foreach ($items as $item) {
		$target = $to . '/' . $items->getSubPathname();
		if ($item->isDir()) {
			if (!is_dir($target)) {
				mkdir($target, 0755, true);
			}
		} else {
			copy($item->getPathname(), $target);
		}
	}
}

// ---------------------------------------------------------------------------
// Requirements
// ---------------------------------------------------------------------------

function requirements(string $root, string $storage): array
{
	$checks = [];
	$add = function (string $label, string $status, string $detail = '') use (&$checks) {
		$checks[] = compact('label', 'status', 'detail');
	};

	$add('PHP ' . KOKEN_MIN_PHP . ' or newer', version_compare(PHP_VERSION, KOKEN_MIN_PHP, '>=') ? 'ok' : 'fail', 'PHP ' . PHP_VERSION);

	foreach (['mysqli' => 'database access', 'curl' => 'Koken talks to its own API via HTTP', 'json' => '', 'mbstring' => 'multibyte text', 'zip' => 'theme and plugin uploads'] as $ext => $why) {
		$add("PHP extension $ext", extension_loaded($ext) ? 'ok' : 'fail', $why);
	}

	$imagick = extension_loaded('imagick');
	$gd = extension_loaded('gd');
	$add('Image processing (Imagick or GD)', ($imagick || $gd) ? 'ok' : 'fail', implode(', ', array_filter([$imagick ? 'Imagick' : '', $gd ? 'GD' : ''])) ?: 'neither available');
	$add('PHP extension exif', extension_loaded('exif') ? 'ok' : 'warn', 'reads camera data from photos');

	$add('storage/ writable', writable_dir($storage) ? 'ok' : 'fail', $storage);
	$add('.htaccess writable', (is_file($root . '/.htaccess') ? is_writable($root . '/.htaccess') : is_writable($root)) ? 'ok' : 'warn', 'needed for pretty URLs');

	$controller = $root . '/app/application/controllers/install.php';
	$add('Koken install routine present', is_file($controller) ? 'ok' : 'fail', is_file($controller) ? '' : 'app/application/controllers/install.php is missing – it is deleted after an installation. Restore it from the package (git checkout).');

	$upload = ini_get('upload_max_filesize');
	$add('Upload limit', 'ok', 'upload_max_filesize = ' . $upload . ', post_max_size = ' . ini_get('post_max_size'));

	if (extension_loaded('curl')) {
		$mode = detect_loopback();
		if ($mode === null) {
			$add('Loopback HTTP requests', 'fail', 'The server cannot reach itself via HTTP (' . h($_SERVER['HTTP_HOST']) . '). Koken needs this for its API.');
		} else {
			$add('Loopback HTTP requests', 'ok', $mode ? 'via server address + Host header (LOOPBACK_HOST_HEADER)' : 'direct');
		}
	}

	return $checks;
}

// ---------------------------------------------------------------------------
// Installation
// ---------------------------------------------------------------------------

function run_install(string $root, string $storage, string $defaults, array $db, array $admin, bool $host_header): array
{
	// 1. storage skeleton
	foreach (['', '/configuration', '/originals', '/cache', '/tmp', '/plugins', '/custom', '/themes'] as $dir) {
		$path = $storage . $dir;
		if (!is_dir($path) && !mkdir($path, 0755, true)) {
			return ['ok' => false, 'error' => "Could not create $path"];
		}
		if ($dir !== '' && !is_file("$path/index.html")) {
			file_put_contents("$path/index.html", '');
		}
	}

	// 2. default theme
	if (is_dir($defaults . '/themes')) {
		foreach (glob($defaults . '/themes/*', GLOB_ONLYDIR) as $theme) {
			$target = $storage . '/themes/' . basename($theme);
			if (!is_dir($target)) {
				copy_tree($theme, $target);
			}
		}
	}

	// 3. user_setup.php (server specific settings)
	$user_setup = $storage . '/configuration/user_setup.php';
	if (!is_file($user_setup)) {
		$loopback = $host_header ? "define('LOOPBACK_HOST_HEADER', true);" : "// define('LOOPBACK_HOST_HEADER', true);";
		file_put_contents($user_setup, <<<PHP
<?php

	// Path to ImageMagick on your server, if it is in a non-standard location.
	// define('MAGICK_PATH', 'convert');

	// Path to ffmpeg on your server (video support)
	// define('FFMPEG_PATH', 'ffmpeg');

	// By default, Koken makes requests in parallel to improve performance.
	// On some hosts, this can cause you to exceed your resource allotment.
	// Uncomment this line and/or lower the number if you are having issues.
	// define('MAX_PARALLEL_REQUESTS', 4);

	// Koken calls its own API via HTTP. Behind a Docker port mapping or a
	// reverse proxy this must go to the server address with a Host header.
	$loopback

PHP);
	}

	// 4. Koken's own installation routine (schema, settings, user, theme)
	$r = loopback($host_header, '/api.php?/install/complete', [
		'database' => $db + ['driver' => 'mysqli', 'socket' => ''],
		'first_name' => $admin['first_name'],
		'last_name' => $admin['last_name'],
		'email' => $admin['email'],
		'password' => $admin['password'],
		'timezone' => $admin['timezone'],
		'theme' => 'elementary',
	], 300);

	$json = json_decode($r['body'], true);
	if ($r['code'] !== 200 || empty($json['success'])) {
		$detail = $json['error'] ?? ($r['error'] ?: trim(strip_tags($r['body'])));
		return ['ok' => false, 'error' => 'Koken install routine failed (HTTP ' . $r['code'] . '): ' . mb_substr($detail, 0, 500)];
	}

	return ['ok' => true];
}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

// Used by the loopback check
if (isset($_GET['ping'])) {
	header('Content-Type: text/plain');
	exit('koken-installer-pong');
}

$token = env('KOKEN_INSTALL_TOKEN');
if (isset($_GET['token']) && $token !== '' && hash_equals($token, (string) $_GET['token'])) {
	$_SESSION['token_ok'] = true;
}
$token_ok = $token === '' || !empty($_SESSION['token_ok']);

if (empty($_SESSION['csrf'])) {
	$_SESSION['csrf'] = bin2hex(random_bytes(16));
}

$step = $_SESSION['step'] ?? 'check';
$errors = [];
$installed = is_installed($STORAGE);

if ($installed && $step !== 'done') {
	$step = 'installed';
} elseif (!$token_ok) {
	$step = 'token';
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $token_ok && !$installed) {
	if (!hash_equals($_SESSION['csrf'], (string) ($_POST['csrf'] ?? ''))) {
		$errors[] = 'Your session has expired. Please try again.';
	} elseif (isset($_POST['back'])) {
		$step = $_POST['back'] === 'db' ? 'db' : 'check';
	} elseif ($step === 'check') {
		$step = 'db';
	} elseif ($step === 'db') {
		$docker = docker_db();
		if ($docker && !empty($_POST['use_docker'])) {
			$db = $docker;
		} else {
			$db = [
				'hostname' => trim((string) ($_POST['hostname'] ?? '')),
				'database' => trim((string) ($_POST['database'] ?? '')),
				'username' => trim((string) ($_POST['username'] ?? '')),
				'password' => (string) ($_POST['password'] ?? ''),
				'prefix' => trim((string) ($_POST['prefix'] ?? '')),
			];
		}
		$_SESSION['db_form'] = array_diff_key($db, ['password' => true]) + ['use_docker' => !empty($_POST['use_docker'])];

		if ($db['hostname'] === '' || $db['database'] === '' || $db['username'] === '') {
			$errors[] = 'Please fill in host, database and user.';
		} elseif ($db['prefix'] !== '' && !preg_match('/^[a-zA-Z0-9_]+$/', $db['prefix'])) {
			$errors[] = 'The table prefix may only contain letters, digits and underscores.';
		} else {
			$link = db_connect($db, $error);
			if (!$link) {
				$errors[] = 'Could not connect to the database: ' . $error;
			} elseif (koken_user_count($link, $db['prefix']) !== null) {
				$errors[] = 'This database already contains a Koken installation (table ' . $db['prefix'] . 'users). Use another database or table prefix.';
			} else {
				$_SESSION['db'] = $db;
				$step = 'admin';
			}
		}
	} elseif ($step === 'admin') {
		$admin = [
			'first_name' => trim((string) ($_POST['first_name'] ?? '')),
			'last_name' => trim((string) ($_POST['last_name'] ?? '')),
			'email' => trim((string) ($_POST['email'] ?? '')),
			'password' => (string) ($_POST['password'] ?? ''),
			'timezone' => (string) ($_POST['timezone'] ?? 'UTC'),
		];
		$_SESSION['admin_form'] = array_diff_key($admin, ['password' => true]);

		if ($admin['first_name'] === '' || $admin['last_name'] === '') {
			$errors[] = 'Please enter first and last name (used as the initial site title).';
		}
		if (!filter_var($admin['email'], FILTER_VALIDATE_EMAIL)) {
			$errors[] = 'Please enter a valid e-mail address – it is your login name.';
		}
		if (strlen($admin['password']) < 8) {
			$errors[] = 'The password must have at least 8 characters.';
		} elseif ($admin['password'] !== (string) ($_POST['password2'] ?? '')) {
			$errors[] = 'The passwords do not match.';
		}
		if (!in_array($admin['timezone'], DateTimeZone::listIdentifiers(), true)) {
			$errors[] = 'Please choose a time zone.';
		}

		if (!$errors && empty($_SESSION['db'])) {
			$step = 'db';
		} elseif (!$errors) {
			$host_header = detect_loopback();
			if ($host_header === null) {
				$errors[] = 'The server cannot reach itself via HTTP. Please check the requirements.';
			} else {
				set_time_limit(0);
				$result = run_install($ROOT, $STORAGE, $DEFAULTS, $_SESSION['db'], $admin, $host_header);
				if ($result['ok']) {
					$_SESSION = ['step' => 'done', 'email' => $admin['email'], 'csrf' => $_SESSION['csrf']];
					$step = 'done';
				} else {
					$errors[] = $result['error'];
				}
			}
		}
	}

	if (!$errors && $step !== 'done') {
		$_SESSION['step'] = $step;
		header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?'));
		exit;
	}
	$_SESSION['step'] = $step;
}

if ($step === 'done') {
	// Show the success page once, then behave like "installed"
	unset($_SESSION['step']);
}

$checks = $step === 'check' ? requirements($ROOT, $STORAGE) : [];
$blocking = array_filter($checks, fn($c) => $c['status'] === 'fail');
$docker = docker_db();
$db_form = ($_SESSION['db_form'] ?? []) + ['hostname' => 'localhost', 'database' => 'koken', 'username' => '', 'prefix' => 'koken_', 'use_docker' => (bool) $docker];
$admin_form = ($_SESSION['admin_form'] ?? []) + ['first_name' => '', 'last_name' => '', 'email' => '', 'timezone' => env('TZ', 'Europe/Berlin')];
$steps = ['check' => 'Requirements', 'db' => 'Database', 'admin' => 'Your account', 'done' => 'Done'];

header('Content-Type: text/html; charset=utf-8');
header('X-Frame-Options: DENY');
header('Cache-Control: no-store');
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Koken Installer</title>
<style>
	:root { --bg: #f4f4f2; --card: #fff; --text: #222; --muted: #6b6b6b; --line: #e2e2de; --accent: #1f6feb; --ok: #1a7f37; --warn: #9a6700; --fail: #cf222e; }
	@media (prefers-color-scheme: dark) { :root { --bg: #161616; --card: #1f1f1f; --text: #e8e8e8; --muted: #9a9a9a; --line: #333; --accent: #4c8dff; --ok: #3fb950; --warn: #d29922; --fail: #f85149; } }
	* { box-sizing: border-box; }
	body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
	main { max-width: 640px; margin: 48px auto; padding: 0 16px; }
	h1 { font-size: 22px; font-weight: 600; margin: 0 0 4px; }
	.sub { color: var(--muted); margin: 0 0 24px; }
	.card { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 24px; }
	ol.steps { display: flex; gap: 8px; list-style: none; padding: 0; margin: 0 0 20px; font-size: 13px; color: var(--muted); flex-wrap: wrap; }
	ol.steps li { padding: 4px 10px; border-radius: 99px; border: 1px solid var(--line); }
	ol.steps li.active { color: var(--text); border-color: var(--accent); }
	table { width: 100%; border-collapse: collapse; }
	td { padding: 8px 4px; border-bottom: 1px solid var(--line); vertical-align: top; }
	td.st { width: 60px; font-weight: 600; font-size: 13px; }
	.ok { color: var(--ok); } .warn { color: var(--warn); } .fail { color: var(--fail); }
	.detail { color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
	label { display: block; font-weight: 500; margin: 14px 0 4px; }
	input[type=text], input[type=email], input[type=password], select { width: 100%; padding: 9px 10px; border: 1px solid var(--line); border-radius: 6px; background: var(--bg); color: var(--text); font: inherit; }
	.row { display: flex; gap: 12px; } .row > div { flex: 1; }
	.check { display: flex; gap: 8px; align-items: flex-start; margin-top: 8px; font-weight: 400; }
	.hint { color: var(--muted); font-size: 13px; margin: 4px 0 0; }
	.errors { border: 1px solid var(--fail); color: var(--fail); border-radius: 6px; padding: 10px 14px; margin-bottom: 16px; }
	.actions { display: flex; justify-content: space-between; gap: 12px; margin-top: 24px; }
	button, a.button { appearance: none; border: 0; border-radius: 6px; padding: 10px 18px; font: inherit; font-weight: 600; cursor: pointer; background: var(--accent); color: #fff; text-decoration: none; display: inline-block; }
	button.secondary { background: transparent; color: var(--muted); border: 1px solid var(--line); }
	button:disabled { opacity: .5; cursor: not-allowed; }
	#manual-db[hidden] { display: none; }
	@media (max-width: 520px) { .row { flex-direction: column; gap: 0; } }
</style>
</head>
<body>
<main>
	<h1>Koken</h1>
	<p class="sub">Installation – PHP <?= h(PHP_VERSION) ?></p>

	<?php if (isset($steps[$step])): ?>
	<ol class="steps">
		<?php foreach ($steps as $key => $label): ?>
			<li class="<?= $key === $step ? 'active' : '' ?>"><?= h($label) ?></li>
		<?php endforeach ?>
	</ol>
	<?php endif ?>

	<div class="card">
	<?php if ($errors): ?>
		<div class="errors"><?php foreach ($errors as $e): ?><div><?= h($e) ?></div><?php endforeach ?></div>
	<?php endif ?>

	<?php if ($step === 'installed'): ?>
		<p><strong>Koken is already installed.</strong></p>
		<p>The installer is locked. Go to your <a href="<?= h(site_url('/')) ?>">site</a> or the <a href="<?= h(site_url('/admin/')) ?>">admin console</a>.</p>

	<?php elseif ($step === 'token'): ?>
		<p><strong>Installer locked.</strong></p>
		<p>Open the installer with the link printed by <code>setup.sh</code> (it contains the installation token), or set it with <code>?token=…</code>. The token is stored as <code>KOKEN_INSTALL_TOKEN</code> in your <code>.env</code> file.</p>

	<?php elseif ($step === 'check'): ?>
		<form method="post">
			<input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>">
			<table>
			<?php foreach ($checks as $c): ?>
				<tr>
					<td class="st <?= h($c['status']) ?>"><?= ['ok' => 'OK', 'warn' => 'Note', 'fail' => 'Error'][$c['status']] ?></td>
					<td><?= h($c['label']) ?><?php if ($c['detail'] !== ''): ?><div class="detail"><?= h($c['detail']) ?></div><?php endif ?></td>
				</tr>
			<?php endforeach ?>
			</table>
			<div class="actions">
				<span></span>
				<?php if ($blocking): ?>
					<button type="button" onclick="location.reload()">Check again</button>
				<?php else: ?>
					<button type="submit">Continue</button>
				<?php endif ?>
			</div>
		</form>

	<?php elseif ($step === 'db'): ?>
		<form method="post">
			<input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>">
			<?php if ($docker): ?>
				<label class="check">
					<input type="checkbox" name="use_docker" value="1" <?= $db_form['use_docker'] ? 'checked' : '' ?> onchange="document.getElementById('manual-db').hidden = this.checked">
					<span>Use the database prepared by Docker<br><span class="hint">Database <code><?= h($docker['database']) ?></code> on <code><?= h($docker['hostname']) ?></code>, user <code><?= h($docker['username']) ?></code>, table prefix <code><?= h($docker['prefix']) ?></code> (from <code>.env</code>)</span></span>
				</label>
			<?php endif ?>
			<div id="manual-db" <?= ($docker && $db_form['use_docker']) ? 'hidden' : '' ?>>
				<div class="row">
					<div><label for="hostname">Database host</label><input type="text" id="hostname" name="hostname" value="<?= h($db_form['hostname']) ?>"><p class="hint">e.g. localhost, db:3306</p></div>
					<div><label for="database">Database name</label><input type="text" id="database" name="database" value="<?= h($db_form['database']) ?>"></div>
				</div>
				<div class="row">
					<div><label for="username">User</label><input type="text" id="username" name="username" value="<?= h($db_form['username']) ?>" autocomplete="off"></div>
					<div><label for="password">Password</label><input type="password" id="password" name="password" autocomplete="new-password"></div>
				</div>
				<label for="prefix">Table prefix</label><input type="text" id="prefix" name="prefix" value="<?= h($db_form['prefix']) ?>">
			</div>
			<div class="actions">
				<button type="submit" name="back" value="check" class="secondary">Back</button>
				<button type="submit">Continue</button>
			</div>
		</form>

	<?php elseif ($step === 'admin'): ?>
		<form method="post" onsubmit="this.querySelector('[type=submit]:not(.secondary)').disabled = true; this.querySelector('.busy').hidden = false;">
			<input type="hidden" name="csrf" value="<?= h($_SESSION['csrf']) ?>">
			<div class="row">
				<div><label for="first_name">First name</label><input type="text" id="first_name" name="first_name" value="<?= h($admin_form['first_name']) ?>" required></div>
				<div><label for="last_name">Last name</label><input type="text" id="last_name" name="last_name" value="<?= h($admin_form['last_name']) ?>" required></div>
			</div>
			<label for="email">E-mail (login)</label><input type="email" id="email" name="email" value="<?= h($admin_form['email']) ?>" required>
			<div class="row">
				<div><label for="password">Password</label><input type="password" id="password" name="password" minlength="8" autocomplete="new-password" required></div>
				<div><label for="password2">Repeat password</label><input type="password" id="password2" name="password2" minlength="8" autocomplete="new-password" required></div>
			</div>
			<label for="timezone">Time zone</label>
			<select id="timezone" name="timezone">
				<?php foreach (DateTimeZone::listIdentifiers() as $tz): ?>
					<option <?= $tz === $admin_form['timezone'] ? 'selected' : '' ?>><?= h($tz) ?></option>
				<?php endforeach ?>
			</select>
			<p class="hint">Your name becomes the initial site title – you can change everything later in the admin console.</p>
			<div class="actions">
				<button type="submit" name="back" value="db" class="secondary" formnovalidate>Back</button>
				<button type="submit">Install Koken</button>
			</div>
			<p class="hint busy" hidden>Installing … this takes a few seconds.</p>
		</form>

	<?php elseif ($step === 'done'): ?>
		<p><strong>Koken has been installed.</strong></p>
		<p>Sign in to the admin console with <code><?= h($_SESSION['email'] ?? '') ?></code> and your password.</p>
		<div class="actions">
			<a class="button" href="<?= h(site_url('/admin/')) ?>">Open admin console</a>
			<a href="<?= h(site_url('/')) ?>">View site</a>
		</div>
		<p class="hint">The installer is now locked.</p>
	<?php endif ?>
	</div>
</main>
</body>
</html>
