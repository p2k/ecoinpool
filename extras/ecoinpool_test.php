<?php

require_once("ecoinpool.php");

$c = new EcoinpoolClient("ecoinpool", "localtest");
$c->default_sub_pool_id = "11122233344455566677788899900000";

$w = new EcoinpoolWorker(1, "test123");
var_dump($w);

$c->saveWorker($w);
$w_id = $w->_id;
echo "\nSaved with ID: $w_id\n\n";

unset($w);

$w = $c->workerWithId($w_id);
$w->setLongpolling(false);
$c->saveWorker($w);

var_dump($c->workersWithUserId(1));

$c->deleteWorker($w);

?>
