<?php
/*
 * raspi-ham remote control panel
 * upload this + phpMQTT.php to your web server
 * creates its own SQLite database for command history
 *
 * when you tap a button:
 *   1. saves to SQLite (history)
 *   2. publishes MQTT message → Pi gets it instantly (<1s)
 *   3. Pi publishes status back → page shows live status
 */

$DB_FILE = __DIR__ . '/raspi-ham.db';

// ---- MQTT broker config (HiveMQ Cloud free tier) ----
$MQTT_HOST   = 'your-cluster.s1.eu.hivemq.cloud';  // change this
$MQTT_PORT   = 8883;  // TLS
$MQTT_USER   = 'raspi-ham';    // set in HiveMQ console
$MQTT_PASS   = 'change-me';   // set in HiveMQ console

// MQTT topics
$TOPIC_CMD    = 'raspi-ham/cmd';     // panel → pi
$TOPIC_STATUS = 'raspi-ham/status';  // pi → panel (via retained messages)

// ---- database (for command history only, MQTT handles the real-time part) ----

$db = new SQLite3($DB_FILE);
$db->exec('CREATE TABLE IF NOT EXISTS commands (
    id INTEGER PRIMARY KEY,
    type TEXT NOT NULL,
    value TEXT NOT NULL,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
)');
$db->exec('CREATE TABLE IF NOT EXISTS status (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
)');

$db->exec("INSERT OR IGNORE INTO status (key, value) VALUES ('wifi', 'unknown')");
$db->exec("INSERT OR IGNORE INTO status (key, value) VALUES ('mode', 'unknown')");
$db->exec("INSERT OR IGNORE INTO status (key, value) VALUES ('last_seen', 'never')");

// ---- MQTT publish helper ----

function mqtt_publish($topic, $message) {
    global $MQTT_HOST, $MQTT_PORT, $MQTT_USER, $MQTT_PASS;

    require_once __DIR__ . '/phpMQTT.php';

    $client_id = 'raspi-ham-web-' . rand(1000, 9999);
    $mqtt = new Bluerhinos\phpMQTT($MQTT_HOST, $MQTT_PORT, $client_id, cafile: true);

    if ($mqtt->connect(true, null, $MQTT_USER, $MQTT_PASS)) {
        $mqtt->publish($topic, $message, 1, false);  // QoS 1 = at least once
        $mqtt->close();
        return true;
    }
    return false;
}

// ---- status update endpoint (Pi posts status here as backup) ----

if (isset($_GET['api']) && $_GET['api'] === 'status') {
    header('Content-Type: application/json');
    $data = json_decode(file_get_contents('php://input'), true);
    if ($data) {
        foreach (['wifi', 'mode', 'last_seen'] as $key) {
            if (isset($data[$key])) {
                $stmt = $db->prepare("INSERT OR REPLACE INTO status (key, value, updated_at) VALUES (:k, :v, datetime('now'))");
                $stmt->bindValue(':k', $key, SQLITE3_TEXT);
                $stmt->bindValue(':v', $data[$key], SQLITE3_TEXT);
                $stmt->execute();
            }
        }
    }
    echo json_encode(['ok' => true]);
    exit;
}

// ---- handle panel form submissions ----

$msg = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $type = $_POST['type'] ?? '';
    $value = $_POST['value'] ?? '';

    $valid = [
        'wifi'   => ['hotspot', 'home'],
        'mode'   => ['sdr', 'adsb', 'monitor', 'managed'],
        'bias_t' => ['on', 'off'],
    ];

    if (isset($valid[$type]) && in_array($value, $valid[$type])) {
        // save to history
        $stmt = $db->prepare("INSERT INTO commands (type, value) VALUES (:type, :value)");
        $stmt->bindValue(':type', $type, SQLITE3_TEXT);
        $stmt->bindValue(':value', $value, SQLITE3_TEXT);
        $stmt->execute();

        // publish to MQTT → Pi gets it instantly
        $payload = json_encode(['type' => $type, 'value' => $value, 'ts' => time()]);
        if (mqtt_publish($TOPIC_CMD, $payload)) {
            $msg = "sent: $type → $value";
        } else {
            $msg = "saved but MQTT publish failed — check broker config";
        }
    } else {
        $msg = "invalid command";
    }

    header('Location: ' . $_SERVER['PHP_SELF'] . '?msg=' . urlencode($msg));
    exit;
}

// ---- get current status for display ----

$status = [];
$result = $db->query("SELECT key, value, updated_at FROM status");
while ($row = $result->fetchArray(SQLITE3_ASSOC)) {
    $status[$row['key']] = $row;
}

$recent = $db->query(
    "SELECT type, value, created_at FROM commands ORDER BY id DESC LIMIT 10"
);

$msg = $_GET['msg'] ?? '';
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>raspi-ham control</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #0a0a0a;
            color: #e0e0e0;
            padding: 20px;
            max-width: 600px;
            margin: 0 auto;
        }
        h1 { font-size: 1.4em; margin-bottom: 4px; color: #00ff88; }
        h2 { margin: 20px 0 10px; color: #888; text-transform: uppercase; font-size: 0.8em; letter-spacing: 1px; }
        .status-grid {
            display: grid;
            grid-template-columns: 1fr 1fr 1fr;
            gap: 10px;
            margin: 15px 0;
        }
        .status-card {
            background: #1a1a1a;
            border: 1px solid #333;
            border-radius: 8px;
            padding: 12px;
            text-align: center;
        }
        .status-card .label { font-size: 0.75em; color: #666; text-transform: uppercase; }
        .status-card .value { font-size: 1.1em; margin-top: 4px; color: #00ff88; font-weight: bold; }
        .btn-group { display: flex; gap: 8px; margin: 8px 0; }
        .btn {
            flex: 1;
            padding: 14px 10px;
            border: 1px solid #333;
            border-radius: 8px;
            background: #1a1a1a;
            color: #e0e0e0;
            font-size: 0.95em;
            cursor: pointer;
            text-align: center;
            transition: all 0.15s;
        }
        .btn:active { background: #00ff88; color: #000; }
        .btn-hotspot { border-color: #ff6b35; }
        .btn-hotspot:active { background: #ff6b35; }
        .btn-home { border-color: #4a9eff; }
        .btn-home:active { background: #4a9eff; }
        .msg {
            background: #1a3a1a;
            border: 1px solid #00ff88;
            border-radius: 6px;
            padding: 10px;
            margin: 10px 0;
            font-size: 0.85em;
        }
        table { width: 100%; border-collapse: collapse; font-size: 0.8em; margin-top: 8px; }
        td, th { padding: 6px 8px; text-align: left; border-bottom: 1px solid #222; }
        th { color: #666; }
        .sub { color: #555; font-size: 0.8em; }
    </style>
</head>
<body>
    <h1>raspi-ham</h1>
    <span class="sub">remote control &middot; mqtt push</span>

    <?php if ($msg): ?>
        <div class="msg"><?= htmlspecialchars($msg) ?></div>
    <?php endif; ?>

    <div class="status-grid">
        <div class="status-card">
            <div class="label">WiFi</div>
            <div class="value"><?= htmlspecialchars($status['wifi']['value'] ?? '?') ?></div>
        </div>
        <div class="status-card">
            <div class="label">Mode</div>
            <div class="value"><?= htmlspecialchars($status['mode']['value'] ?? '?') ?></div>
        </div>
        <div class="status-card">
            <div class="label">Last Seen</div>
            <div class="value" style="font-size:0.75em"><?= htmlspecialchars($status['last_seen']['value'] ?? 'never') ?></div>
        </div>
    </div>

    <h2>WiFi</h2>
    <div class="btn-group">
        <form method="post" style="flex:1;display:flex">
            <input type="hidden" name="type" value="wifi">
            <input type="hidden" name="value" value="hotspot">
            <button class="btn btn-hotspot" type="submit">Phone Hotspot</button>
        </form>
        <form method="post" style="flex:1;display:flex">
            <input type="hidden" name="type" value="wifi">
            <input type="hidden" name="value" value="home">
            <button class="btn btn-home" type="submit">Home WiFi</button>
        </form>
    </div>

    <h2>SDR Mode</h2>
    <div class="btn-group">
        <form method="post" style="flex:1;display:flex">
            <input type="hidden" name="type" value="mode">
            <input type="hidden" name="value" value="sdr">
            <button class="btn" type="submit">SDR</button>
        </form>
        <form method="post" style="flex:1;display:flex">
            <input type="hidden" name="type" value="mode">
            <input type="hidden" name="value" value="adsb">
            <button class="btn" type="submit">ADS-B</button>
        </form>
    </div>

    <h2>WiFi Monitor</h2>
    <div class="btn-group">
        <form method="post" style="flex:1;display:flex">
            <input type="hidden" name="type" value="mode">
            <input type="hidden" name="value" value="monitor">
            <button class="btn" type="submit">Monitor On</button>
        </form>
        <form method="post" style="flex:1;display:flex">
            <input type="hidden" name="type" value="mode">
            <input type="hidden" name="value" value="managed">
            <button class="btn" type="submit">Monitor Off</button>
        </form>
    </div>

    <h2>Bias-T (LNA Power)</h2>
    <div class="btn-group">
        <form method="post" style="flex:1;display:flex">
            <input type="hidden" name="type" value="bias_t">
            <input type="hidden" name="value" value="on">
            <button class="btn" type="submit">Bias-T On</button>
        </form>
        <form method="post" style="flex:1;display:flex">
            <input type="hidden" name="type" value="bias_t">
            <input type="hidden" name="value" value="off">
            <button class="btn" type="submit">Bias-T Off</button>
        </form>
    </div>

    <h2>Recent Commands</h2>
    <table>
        <tr><th>Command</th><th>Time</th></tr>
        <?php while ($row = $recent->fetchArray(SQLITE3_ASSOC)): ?>
        <tr>
            <td><?= htmlspecialchars($row['type']) ?> &rarr; <?= htmlspecialchars($row['value']) ?></td>
            <td class="sub"><?= htmlspecialchars($row['created_at']) ?></td>
        </tr>
        <?php endwhile; ?>
    </table>

    <p class="sub" style="margin-top:20px;text-align:center">
        commands delivered via MQTT (~1s) &middot; <a href="?" style="color:#4a9eff">refresh</a>
    </p>
</body>
</html>
