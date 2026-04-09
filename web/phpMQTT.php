<?php
/*
 * phpMQTT - lightweight MQTT client for PHP
 * source: https://github.com/bluerhinos/phpMQTT
 * license: MIT
 *
 * minimal version for raspi-ham - publish only, TLS support
 * if you need the full version, grab it from the repo above
 */

namespace Bluerhinos;

class phpMQTT
{
    private $socket;
    private $msgid = 1;
    private string $address;
    private int $port;
    private string $clientid;
    private bool $cafile;

    public function __construct(string $address, int $port, string $clientid, bool $cafile = false)
    {
        $this->address = $address;
        $this->port = $port;
        $this->clientid = $clientid;
        $this->cafile = $cafile;
    }

    public function connect(bool $clean = true, ?array $will = null, ?string $username = null, ?string $password = null): bool
    {
        if ($this->cafile) {
            $context = stream_context_create([
                'ssl' => [
                    'verify_peer' => true,
                    'verify_peer_name' => true,
                ],
            ]);
            $this->socket = stream_socket_client(
                'tls://' . $this->address . ':' . $this->port,
                $errno, $errstr, 30,
                STREAM_CLIENT_CONNECT, $context
            );
        } else {
            $this->socket = stream_socket_client(
                'tcp://' . $this->address . ':' . $this->port,
                $errno, $errstr, 30
            );
        }

        if (!$this->socket) return false;
        stream_set_timeout($this->socket, 5);

        // build CONNECT packet
        $payload = $this->writeString($this->clientid);

        // protocol header
        $head = chr(0x00) . chr(0x04) . 'MQTT' . chr(0x04); // MQTT 3.1.1

        $flags = 0;
        if ($clean) $flags |= 0x02;

        if ($will) {
            $flags |= 0x04;
            if ($will['qos'] ?? 0) $flags |= (($will['qos'] & 0x03) << 3);
            if ($will['retain'] ?? false) $flags |= 0x20;
            $payload .= $this->writeString($will['topic']);
            $payload .= $this->writeString($will['content']);
        }

        if ($username) {
            $flags |= 0x80;
            $payload .= $this->writeString($username);
        }
        if ($password) {
            $flags |= 0x40;
            $payload .= $this->writeString($password);
        }

        $head .= chr($flags);
        $head .= chr(0x00) . chr(0x3c); // keepalive 60s

        $packet = chr(0x10) . $this->encodeLength(strlen($head) + strlen($payload)) . $head . $payload;
        fwrite($this->socket, $packet);

        $response = $this->read(4);
        if (!$response || strlen($response) < 4) return false;
        return ord($response[3]) === 0;
    }

    public function publish(string $topic, string $content, int $qos = 0, bool $retain = false): void
    {
        $head = chr(0x30 | ($retain ? 0x01 : 0) | ($qos << 1));
        $payload = $this->writeString($topic);
        if ($qos > 0) {
            $payload .= chr($this->msgid >> 8) . chr($this->msgid & 0xff);
            $this->msgid++;
        }
        $payload .= $content;
        fwrite($this->socket, $head . $this->encodeLength(strlen($payload)) . $payload);
    }

    public function close(): void
    {
        if ($this->socket) {
            fwrite($this->socket, chr(0xe0) . chr(0x00));
            fclose($this->socket);
        }
    }

    private function writeString(string $str): string
    {
        $len = strlen($str);
        return chr($len >> 8) . chr($len & 0xff) . $str;
    }

    private function encodeLength(int $len): string
    {
        $str = '';
        do {
            $digit = $len % 128;
            $len >>= 7;
            if ($len > 0) $digit |= 0x80;
            $str .= chr($digit);
        } while ($len > 0);
        return $str;
    }

    private function read(int $len): string|false
    {
        $data = '';
        while (strlen($data) < $len) {
            $chunk = fread($this->socket, $len - strlen($data));
            if ($chunk === false || $chunk === '') return false;
            $data .= $chunk;
        }
        return $data;
    }
}
