<?php

// Short note: you need mcrypt for encryption support

class EcoinpoolClient
{
    private $db_auth = false;
    private $db_host;
    private $db_port;
    private $db_prefix;
    
    private $sub_pool_cache;
    
    public $default_sub_pool_id = NULL; // You may change this
    public $blowfish_secret = NULL; // You may change this too
    
    public function __construct($db_user = false, $db_pass = false, $db_host = "localhost", $db_port = 5984, $db_prefix = "")
    {
        if ($db_user !== false || $db_pass !== false)
            $this->db_auth = "Basic " . base64_encode("$db_user:$db_pass");
        $this->db_host = $db_host;
        $this->db_port = $db_port;
        $this->db_prefix = $db_prefix;
        
        $this->sub_pool_cache = array();
    }
    
    public function saveWorker($worker)
    {
        if ($worker->sub_pool_id === NULL)
            $worker->sub_pool_id = $this->default_sub_pool_id;
        
        $worker_doc = $this->serializeWorker($worker);
        list($worker->_id, $worker->_rev) = $this->putDocument("ecoinpool", $worker_doc);
    }
    
    public function deleteWorker($worker)
    {
        if ($worker->_id === NULL)
            throw new Exception("Worker has no ID!");
        if ($worker->_rev === NULL)
            throw new Exception("Worker has no revision!");
        
        $this->deleteDocument("ecoinpool", $worker->_id, $worker->_rev);
    }
    
    public function workersWithUserId($user_id, $sub_pool_id = NULL)
    {
        if ($sub_pool_id === NULL)
            $sub_pool_id = $this->default_sub_pool_id;
        
        $match = array($sub_pool_id, $user_id);
        $view_data = $this->getView("ecoinpool", "workers", "by_sub_pool_and_user_id", $match, $match, true);
        
        // Parse workers
        $workers = array();
        foreach ($view_data->rows as $row) {
            $workers[] = $this->unserializeWorker($row->doc);
        }
        
        return $workers;
    }
    
    public function setSharesForWorkers($workers)
    {
        $workers_by_subpool = self::SplitWorkersBySubPools($workers);
        foreach ($workers_by_subpool as $sub_pool_id => $sub_pool_workers) {
            $sub_pool = $this->subPoolWithId($sub_pool_id);
            
            $view_data = $this->getViewMultiKey($sub_pool->name, "stats", "workers", array_keys($sub_pool_workers), false, true);
            
            foreach ($view_data->rows as $row) {
                $worker = $sub_pool_workers[$row->key];
                list($worker->shares->invalid, $worker->shares->valid, $worker->shares->candidate) = $row->value;
            }
        }
    }
    
    public function setLastShareForWorkers($workers)
    {
        $workers_by_subpool = self::SplitWorkersBySubPools($workers);
        foreach ($workers_by_subpool as $sub_pool_id => $sub_pool_workers) {
            $sub_pool = $this->subPoolWithId($sub_pool_id);
            
            $view_data = $this->getViewMultiKey($sub_pool->name, "timed_stats", "worker_last_share", array_keys($sub_pool_workers), false, true);
            
            foreach ($view_data->rows as $row) {
                $worker = $sub_pool_workers[$row->key];
                list(list($year, $month, $day, $hour, $minute, $second), $state) = $row->value;
                $worker->last_share_ts = gmmktime($hour, $minute, $second, $month, $day, $year);
                $worker->last_share_state = $state;
            }
        }
    }
    
    public function speedOfWorker($worker, $minutes = 10)
    {
        $sub_pool = $this->subPoolWithId($worker->sub_pool_id);
        
        list($ts, $start_key, $end_key) = self::MakeTimeIntervalKeys(time()-60, $minutes);
        array_unshift($start_key, $worker->id);
        array_unshift($end_key, $worker->id);
        
        $view_data = $this->getView($sub_pool->name, "timed_stats", "valids_per_worker", $start_key, $end_key, false, 0);
        
        $shares = $view_data->rows[0]->value;
        $sps = $shares / ($minutes * 60);
        
        return $sub_pool->hashspeedFromSharespeed($sps);
    }
    
    public function workerSharesPerMinute($worker, $intervals = 11)
    {
        $sub_pool = $this->subPoolWithId($worker->sub_pool_id);
        
        list($ts, $start_key, $end_key) = self::MakeTimeIntervalKeys(time(), $intervals);
        array_unshift($start_key, $worker->id);
        array_unshift($end_key, $worker->id);
        
        $view_data = $this->getView($sub_pool->name, "timed_stats", "valids_per_worker", $start_key, $end_key, false, 6);
        
        $result = array();
        foreach ($view_data->rows as $row) {
            list($k_worker_id, $k_year, $k_month, $k_day, $k_hour, $k_minute) = $row->key;
            $k_ts = gmmktime($k_hour, $k_minute, 0, $k_month, $k_day, $k_year);
            while ($ts < $k_ts) {
                $result[] = 0;
                $ts += 60;
            }
            $result[] = $row->value;
            $ts += 60;
        }
        while (count($result) < $intervals)
            $result[] = 0;
        
        return $result;
    }
    
    public function speedOfSubPool($minutes = 10, $sub_pool_id = NULL)
    {
        if ($sub_pool_id instanceof EcoinpoolSubPool)
            $sub_pool = $sub_pool_id;
        else if ($sub_pool_id == NULL)
            $sub_pool = $this->subPoolWithId($this->default_sub_pool_id);
        else
            $sub_pool = $this->subPoolWithId($sub_pool_id);
        
        list($ts, $start_key, $end_key) = self::MakeTimeIntervalKeys(time()-60, $minutes);
        
        $view_data = $this->getView($sub_pool->name, "timed_stats", "all_valids", $start_key, $end_key, false, 0);
        
        $shares = $view_data->rows[0]->value;
        $sps = $shares / ($minutes * 60);
        
        return $sub_pool->hashspeedFromSharespeed($sps);
    }
    
    public function poolSharesPerMinute($intervals = 11, $sub_pool_id = NULL)
    {
        if ($sub_pool_id instanceof EcoinpoolSubPool)
            $sub_pool = $sub_pool_id;
        else if ($sub_pool_id == NULL)
            $sub_pool = $this->subPoolWithId($this->default_sub_pool_id);
        else
            $sub_pool = $this->subPoolWithId($sub_pool_id);
        
        list($ts, $start_key, $end_key) = self::MakeTimeIntervalKeys(time(), $intervals);
        
        $view_data = $this->getView($sub_pool->name, "timed_stats", "all_valids", $start_key, $end_key, false, 5);
        
        $result = array();
        foreach ($view_data->rows as $row) {
            list($k_year, $k_month, $k_day, $k_hour, $k_minute) = $row->key;
            $k_ts = gmmktime($k_hour, $k_minute, 0, $k_month, $k_day, $k_year);
            while ($ts < $k_ts) {
                $result[] = 0;
                $ts += 60;
            }
            $result[] = $row->value;
            $ts += 60;
        }
        while (count($result) < $intervals)
            $result[] = 0;
        
        return $result;
    }
    
    public function workerWithId($worker_id)
    {
        return $this->unserializeWorker($this->getDocument("ecoinpool", $worker_id));
    }
    
    public function subPoolWithId($sub_pool_id)
    {
        if (array_key_exists($sub_pool_id, $this->sub_pool_cache))
            return $this->sub_pool_cache[$sub_pool_id];
        
        $sub_pool = $this->unserializeSubPool($this->getDocument("ecoinpool", $sub_pool_id));
        $this->sub_pool_cache[$sub_pool_id] = $sub_pool;
        return $sub_pool;
    }
    
    const WORKER_FIELDS_FILTER = "@_id@_rev@type@name@pass@user_id@sub_pool_id@";
    private function unserializeWorker($worker_doc)
    {
        $worker = new EcoinpoolWorker($worker_doc->user_id, $worker_doc->name, $worker_doc->sub_pool_id);
        $worker->id = $worker_doc->_id;
        $worker->_rev = $worker_doc->_rev;
        if (property_exists($worker_doc, "pass")) {
            if (is_object($worker_doc->pass)) {
                if ($this->blowfish_secret !== NULL) {
                    $ivec = base64_decode($worker_doc->pass->i, true);
                    $cipher = base64_decode($worker_doc->pass->c, true);
                    $mcrypt = mcrypt_module_open(MCRYPT_BLOWFISH, '', MCRYPT_MODE_CBC, '');
                    if (mcrypt_generic_init($mcrypt, $this->blowfish_secret, $ivec) != -1) {
                        $decrypted = mdecrypt_generic($mcrypt, $cipher);
                        mcrypt_generic_deinit($mcrypt);
                        preg_match("/\\0+$/", $decrypted, $matches, PREG_OFFSET_CAPTURE);
                        if (count($matches) == 1)
                            $worker->pass = substr($decrypted, 0, $matches[0][1]);
                        else
                            $worker->pass = $decrypted;
                    }
                }
            }
            else
                $worker->pass = $worker_doc->pass;
        }
        foreach ($worker_doc as $prop_name => $prop_value) {
            if (strpos(self::WORKER_FIELDS_FILTER, "@$prop_name@") === false)
                $worker->other->$prop_name = $prop_value;
        }
        return $worker;
    }
    
    private function serializeWorker($worker)
    {
        $worker_doc = new stdClass();
        $worker_doc->type = "worker";
        $worker_doc->_id = $worker->id;
        if ($worker->_rev !== NULL)
            $worker_doc->_rev = $worker->_rev;
        $worker_doc->user_id = $worker->user_id;
        $worker_doc->name = $worker->name;
        $worker_doc->sub_pool_id = $worker->sub_pool_id;
        if ($worker->pass !== NULL) {
            if ($this->blowfish_secret !== NULL) {
                $ivec = substr(sha1($worker->name, true), 0, 8);
                $mcrypt = mcrypt_module_open(MCRYPT_BLOWFISH, '', MCRYPT_MODE_CBC, '');
                if (mcrypt_generic_init($mcrypt, $this->blowfish_secret, $ivec) != -1) {
                    $cipher = mcrypt_generic($mcrypt, $worker->pass);
                    mcrypt_generic_deinit($mcrypt);
                    $worker_doc->pass = new stdClass();
                    $worker_doc->pass->c = base64_encode($cipher);
                    $worker_doc->pass->i = base64_encode($ivec);
                }
            }
            else
                $worker_doc->pass = $worker->pass;
        }
        foreach ($worker->other as $prop_name => $prop_value) {
            $worker_doc->$prop_name = $prop_value;
        }
        return $worker_doc;
    }
    
    private function unserializeSubPool($sub_pool_doc)
    {
        $sub_pool = new EcoinpoolSubPool($sub_pool_doc->name, $sub_pool_doc->pool_type, $sub_pool_doc->port, $sub_pool_doc->coin_daemon);
        $sub_pool->id = $sub_pool_doc->_id;
        $sub_pool->_rev = $sub_pool_doc->_rev;
        return $sub_pool;
    }
    
    private function serializeSubPool($sub_pool)
    {
        $sub_pool_doc = new stdClass();
        $sub_pool_doc->name = $sub_pool->name;
        $sub_pool_doc->pool_type = $sub_pool->pool_type;
        $sub_pool_doc->port = $sub_pool->port;
        $sub_pool_doc->coin_daemon = $sub_pool->coin_daemon;
        $sub_pool_doc->_id = $sub_pool->id;
        if ($sub_pool->_rev !== NULL)
            $sub_pool_doc->_rev = $sub_pool->_rev;
        return $sub_pool_doc;
    }
    
    // Public for experimenting; should be private
    public function getView($db_name, $view_id, $view_name, $start_key = NULL, $end_key = NULL, $include_docs = false, $group_level = NULL)
    {
        $url = $this->db_prefix . "/$db_name/_design/$view_id/_view/$view_name";
        $query = array();
        if ($start_key !== NULL)
            $query["start_key"] = json_encode($start_key);
        if ($end_key !== NULL)
            $query["end_key"] = json_encode($end_key);
        if ($include_docs)
            $query["include_docs"] = "true";
        if ($group_level !== NULL)
            $query["group_level"] = $group_level;
        if (count($query) > 0)
            $url .= "?" . http_build_query($query);
        
        list($status, $reason, $headers, $result) = $this->sendJSONRequest("GET", $url);
        if ($status != 200)
            throw new Exception("getView: $status $reason");
        
        return $result;
    }
    
    // Public for experimenting; should be private
    public function getViewMultiKey($db_name, $view_id, $view_name, $keys, $include_docs = false, $group = false)
    {
        $url = $this->db_prefix . "/$db_name/_design/$view_id/_view/$view_name";
        $query = array("keys" => json_encode($keys));
        if ($include_docs)
            $query["include_docs"] = "true";
        if ($group)
            $query["group"] = "true";
        $url .= "?" . http_build_query($query);
        
        list($status, $reason, $headers, $result) = $this->sendJSONRequest("GET", $url);
        if ($status != 200)
            throw new Exception("getViewMultiKey: $status $reason");
        
        return $result;
    }
    
    // Public for experimenting; should be private
    public function getDocument($db_name, $doc_id)
    {
        list($status, $reason, $headers, $doc) = $this->sendJSONRequest("GET", $this->db_prefix . "/$db_name/$doc_id");
        if ($status != 200)
            throw new Exception("getDocument: $status $reason");
        
        return $doc;
    }
    
    // Public for experimenting; should be private
    public function putDocument($db_name, $doc)
    {
        if ($doc->_id === NULL) // Create new document?
            $doc->_id = $this->getUUID();
        
        list($status, $reason, $headers, $ret) = $this->sendJSONRequest("PUT", $this->db_prefix . "/$db_name/$doc->_id", $doc);
        if ($status != 200 && $status != 201)
            throw new Exception("putDocument: $status $reason");
        
        $doc->_rev = $ret->rev;
        
        return array($doc->_id, $doc->_rev);
    }
    
    // Public for experimenting; should be private
    public function deleteDocument($db_name, $doc_id, $doc_rev)
    {
        list($status, $reason, $headers, $ret) = $this->sendJSONRequest("DELETE", $this->db_prefix . "/$db_name/$doc_id?rev=$doc_rev");
        if ($status != 200)
            throw new Exception("deleteDocument: $status $reason");
    }
    
    private function getUUID()
    {
        list($status, $reason, $headers, $result) = $this->sendJSONRequest("GET", "/_uuids");
        if ($status != 200)
            throw new Exception("getUUID: $status $reason");
        
        return $result->uuids[0];
    }
    
    private function sendJSONRequest($method, $url, $post_data = NULL)
    {
        // Open socket
        $s = fsockopen($this->db_host, $this->db_port, $errno, $errstr);
        if (!$s)
            throw new Exception("fsockopen: $errno: $errstr");
        
        // Prepare request
        $request = "$method $url HTTP/1.0\r\n" .
            ($this->db_auth === false ? "" : "Authorization: $this->db_auth\r\n") .
            "User-Agent: ecoinpool-php/1.0\r\n" .
            "Host: $this->db_host:$this->db_port\r\n" .
            "Accept: application/json\r\n" .
            "Connection: close\r\n";
        
        if ($method == "POST" || $method == "PUT") {
            $json_data = json_encode($post_data);
            $request .= "Content-Type: application/json\r\n" .
                "Content-Length: " . strlen($json_data) . "\r\n\r\n" .
                $json_data;
        }
        else
            $request .= "\r\n";
        
        // Send request
        fwrite($s, $request); 
        $response = ""; 
        
        // Receive response
        while (!feof($s)) {
            $response .= fgets($s);
        }
        
        // Split header & body
        list($header, $body) = explode("\r\n\r\n", $response);
        
        // Parse header
        $headers = array();
        $first = true;
        foreach (explode("\r\n", $header) as $line) {
            if ($first) {
                $status = intval(substr($line, 9, 3));
                $reason = substr($line, 13);
                $first = false;
            }
            else {
                $p = strpos($line, ":");
                $headers[strtolower(substr($line, 0, $p))] = substr($line, $p+2);
            }
        }
        
        // Return results
        return array($status, $reason, $headers, json_decode($body));
    }
    
    private static function MakeTimeIntervalKeys($ts, $minutes_to_subtract)
    {
        $end_key = self::SDateToArray(gmdate("Y-m-d-H-i", $ts));
        $ts = gmmktime($end_key[3], $end_key[4], 0, $end_key[1], $end_key[2], $end_key[0]);
        $end_key[5] = 59;
        $ts -= $minutes_to_subtract * 60 - 60;
        $start_key = self::SDateToArray(gmdate("Y-m-d-H-i", $ts));
        $start_key[5] = 0;
        return array($ts, $start_key, $end_key);
    }
    
    private static function SDateToArray($str_date)
    {
        return array_map(function($x) {return intval($x, 10);}, explode("-", $str_date));
    }
    
    private static function SplitWorkersBySubPools($workers)
    {
        $workers_by_subpool = array();
        foreach ($workers as $worker) {
            if (array_key_exists($worker->sub_pool_id, $workers_by_subpool))
                $workers_by_subpool[$worker->sub_pool_id][$worker->id] = $worker;
            else
                $workers_by_subpool[$worker->sub_pool_id] = array($worker->id => $worker);
        }
        return $workers_by_subpool;
    }
}

class EcoinpoolWorker
{
    public $sub_pool_id;
    public $user_id;
    public $name;
    public $other;
    
    public $id = NULL;
    public $_rev = NULL;
    
    public $shares;
    public $last_share_ts = NULL;
    public $last_share_state = NULL;
    
    public function __construct($user_id, $name, $sub_pool_id = NULL)
    {
        $this->user_id = $user_id;
        $this->name = $name;
        $this->sub_pool_id = $sub_pool_id;
        $this->other = new stdClass();
        $this->shares = new stdClass();
        $this->shares->invalid = 0;
        $this->shares->valid = 0;
        $this->shares->candidate = 0;
    }
    
    public function longpolling()
    {
        $enabled = $this->other->lp;
        if ($enabled === NULL)
            return true;
        else
            return $enabled;
    }
    
    public function setLongpolling($enabled)
    {
        $this->other->lp = $enabled;
    }
    
    public function longpollingHeartbeat()
    {
        $enabled = $this->other->lp_heartbeat;
        if ($enabled === NULL)
            return true;
        else
            return $enabled;
    }
    
    public function setLongpollingHeartbeat($enabled)
    {
        $this->other->lp_heartbeat = $enabled;
    }
    
    public function auxLongpolling()
    {
        $enabled = $this->other->aux_lp;
        if ($enabled === NULL)
            return true;
        else
            return $enabled;
    }
    
    public function setAuxLongpolling($enabled)
    {
        $this->other->aux_lp = $enabled;
    }
    
    public function allValidShares()
    {
        return $this->shares->valid + $this->shares->candidate;
    }
    
    public function isActive($minutes_until_idle = 10)
    {
        if ($this->last_share_ts === NULL)
            return false;
        return (time() - $this->last_share_ts < $minutes_until_idle * 60);
    }
}

class EcoinpoolSubPool
{
    public $name;
    public $pass = NULL;
    public $pool_type;
    public $port;
    public $coin_daemon;
    
    public $id = NULL;
    public $_rev = NULL;
    
    public function __construct($name, $pool_type, $port, $coin_daemon = NULL)
    {
        $this->name = $name;
        $this->pool_type = $pool_type;
        $this->port = $port;
        if ($coin_daemon === NULL)
            $this->coin_daemon = stdClass();
        else
            $this->coin_daemon = (object)$coin_daemon;
    }
    
    public function hashspeedFromSharespeed($shares_per_second)
    {
        switch ($this->pool_type) {
            case "ltc":
                return $shares_per_second * 131072;
            default:
                return $shares_per_second * 4294967296;
        }
    }
}

?>