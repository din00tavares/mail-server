<?php
$config['db_dsnw'] = 'sqlite:////var/roundcube/db/sqlite.db?mode=0646';
$config['db_dsnr'] = '';
$config['imap_host'] = 'ssl://stalwart-mail:993';
$config['smtp_host'] = 'ssl://stalwart-mail:465';
$config['username_domain'] = '';
$config['temp_dir'] = '/tmp/roundcube-temp';
$config['skin'] = 'elastic';
$config['request_path'] = '/';
$config['plugins'] = ['archive', 'zipdownload'];

// Disable SSL verification for internal connections to Stalwart Mail
$config['imap_conn_options'] = [
    'ssl' => [
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ],
];

$config['smtp_conn_options'] = [
    'ssl' => [
        'verify_peer'       => false,
        'verify_peer_name'  => false,
        'allow_self_signed' => true,
    ],
];
