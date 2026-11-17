#!/usr/bin/env php
<?php
// Prints "<module folder>\t<alias>" for each module of the Modules folder given as argument.
foreach (glob($argv[1] . '/*/module.json') as $manifest) {
    $alias = json_decode(file_get_contents($manifest))->alias ?? null;
    if (!is_string($alias) || !preg_match('/^[A-Za-z0-9_-]+$/', $alias)) {
        fwrite(STDERR, "[module-aliases] WARNING: no valid alias in {$manifest}, module skipped\n");
        continue;
    }
    echo dirname($manifest), "\t", $alias, "\n";
}
