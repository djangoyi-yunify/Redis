NO_JOINING_NODES_DETECTED_ERR=240
NUMS_OF_REMAIN_NODES_TOO_LESS_ERR=241
DELETED_REPLICA_NODE_REDIS_ROLE_IS_MASTER_ERR=242
REBALANCE_ERR=243
CLUSTER_FORGET_ERR=204
CLUSTER_RESET_ERR=205
CLUSTER_CLUSER_TLS_PORT_ERR=244
CLUSTER_CLUSER_PORT_ERR=245
EXISTS_REDIS_MEMORY_USAGE_TOO_BIG=206
AVERAGE_REDIS_MEMORY_USAGE_TOO_BIG_AFTER_SCALEIN=207
REDIS_COMMAND_EXECUTE_FAIL=210
CHANGE_VXNET_ERR=220
GROUP_MATCHED_ERR=221
CLUSTER_MATCHED_ERR=222
CLUSTER_STATE_NOT_OK=223
LOAD_ACLFILE_ERR=224
ACL_SWITCH_ERR=225
ACL_MANAGE_ERR=226
LXC_UNSUPPORT_ERR=227

ROOT_CONF_DIR=/opt/app/conf/redis-cluster
CHANGED_CONFIG_FILE=$ROOT_CONF_DIR/redis.changed.conf
DEFAULT_CONFIG_FILE=$ROOT_CONF_DIR/redis.default.conf
CHANGED_ACL_FILE=$ROOT_CONF_DIR/aclfile.conf

REDIS_EXPORTER="/data/redis_exporter"
REDIS_EXPORTER_LOGS_DIR="$REDIS_EXPORTER/logs"
REDIS_EXPORTER_PID_FILE="$REDIS_EXPORTER/redis_exporter.pid"

REDIS_DIR=/data/redis
RUNTIME_CONFIG_FILE=$REDIS_DIR/redis.conf
RUNTIME_CONFIG_FILE_TMP=$REDIS_DIR/redis.conf.tmp
RUNTIME_CONFIG_FILE_COOK=$REDIS_DIR/redis.conf.cook
RUNTIME_ACL_FILE=$REDIS_DIR/aclfile.conf
RUNTIME_ACL_FILE_COOK=$REDIS_DIR/aclfile.conf.cook
NODE_CONF_FILE=$REDIS_DIR/nodes-6379.conf
ACL_CLEAR=$REDIS_DIR/acl.clear

execute() {
  local cmd=$1; log --debug "Executing command ..."
  # 在 checkGroupMatchedCommand(){} 存在的情况下，先对各 command 做判断，仅对 redis cluster 有效
  checkGroupMatchedCommandFunction="checkGroupMatchedCommand"
  [[ "$(type -t $checkGroupMatchedCommandFunction)" == "function" ]] && $checkGroupMatchedCommandFunction $cmd
  [ "$(type -t $cmd)" = "function" ] || cmd=_$cmd
  [[ "$cmd" == *measure* ]] || { log --debug "cat nodes-6379.conf:
  $(cat $NODE_CONF_FILE 2>&1 ||true)"
  }
  $cmd ${@:2}
}

initNode() {
  local caddyPath="/data/caddy"
  mkdir -p $caddyPath
  mkdir -p $REDIS_DIR/{logs,tls}
  mkdir -p $REDIS_EXPORTER $REDIS_EXPORTER_LOGS_DIR
  touch $REDIS_DIR/tls/{ca.crt,redis.crt,redis.dh,redis.key}
  touch $RUNTIME_ACL_FILE
  touch $REDIS_EXPORTER_PID_FILE
  chown -R redis.svc $REDIS_DIR
  chown -R caddy.svc $caddyPath
  chown -R prometheus.svc $REDIS_EXPORTER
  local htmlFile=/data/index.html; [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _initNode
}

checkMyRoleSlave() {
  getRedisRole "$MY_IP" | grep -qE "^slave$"
}

stop(){
  if [ -n "${REBUILD_AUDIT}${VERTICAL_SCALING_ROLES}${UPGRADE_AUDIT}" ] && getRedisRole "$MY_IP" | grep -qE "^master$"; then
    local slaveIP
    slaveIP="$(echo -n "$REDIS_NODES" | xargs -n1 | awk -F"/" -v ip="$MY_IP" '{if($5==ip){gid=$1} else{gids[$1]=$5}}END{print gids[gid]}')"
    echo $slaveIP
    [ -n "$slaveIP" ] && {
      log "runRedisCmd -h $slaveIP CLUSTER FAILOVER TAKEOVER"
      runRedisCmd -h "$slaveIP" CLUSTER FAILOVER TAKEOVER
      log "retry 120 1 0 checkMyRoleSlave"
      retry 120 1 0 checkMyRoleSlave
    }
  fi
  _stop
  swapIpAndName
}

initCluster() {
  # 防止新增节点执行
  if [ -n "$JOINING_REDIS_NODES" ]; then return 0; fi
  [ -e "$NODE_CONF_FILE" ] || {
    local tmplConf=/opt/app/conf/redis-cluster/nodes-6379.conf
    sudo -u redis cp $tmplConf $NODE_CONF_FILE
  }
}

init() {
  execute initNode
  initCluster
}

getLoadStatus() {
  local gid
  gid=$(echo "$REDIS_NODES" | xargs -n1 | awk -F/ -v ip="$MY_IP" '$5==ip{print $1}')
  if echo "$REDIS_NODES" | xargs -n1 | awk -F/ -v ip="$MY_IP" -v gid=$gid '$5!=ip && $1==gid {exit 1}'; then
    runRedisCmd Info Persistence | awk -F"[: ]+" 'BEGIN{f=1}$1=="loading"{f=$2} END{exit f}'
  else
    runRedisCmd info Replication | grep -Eq '^(slave[0-9]|master_host):'
  fi
}

start() {
  isNodeInitialized || execute initNode
  if [[ -n "$JOINING_REDIS_NODES" && "$ENABLE_ACL" == "yes" ]] ; then 
    sudo -u redis touch $ACL_CLEAR
    local ACL_CMD node_ip=$(getFirstNodeIpInStableNodesExceptLeavingNodes)
    ACL_CMD="$(getRuntimeNameOfCmd --node-id "$(getParentNodeId $(getFirstNodeIdInStableNodesExceptLeavingNodes))" ACL)"
    # runRedisCmd -h $node_ip $ACL_CMD LIST > $RUNTIME_ACL_FILE
    retry 60 1 0 helperUpdateAclFile $node_ip $ACL_CMD
  fi

  # only exec at first start
  # config files are updated automaticly by reload
  if [ ! -f $RUNTIME_CONFIG_FILE ]; then
    configure
  else
    log "swapIpAndName --reverse"
    swapIpAndName --reverse
  fi
  _start
  if [ -n "${REBUILD_AUDIT}${VERTICAL_SCALING_ROLES}${UPGRADE_AUDIT}" ]; then
    log "retry 86400 1 0 getLoadStatus"
    retry 86400 1 0 getLoadStatus
  fi
}

helperUpdateAclFile(){
  log "update acl file begin..."
  if ! runRedisCmd -h $1 $2 LIST > $RUNTIME_ACL_FILE; then
    log "update acl file failed."
    return 1
  fi
  log "update acl file end."
  return 0
}

checkRedisStateIsOkByInfo(){
  local oKTag="cluster_state:ok" 
  local infoResponse; infoResponse="$(runRedisCmd -h $1 cluster info)"
  [[ "$infoResponse" == *"$oKTag"* ]]
}

getRedisCheckResponse(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  runRedisCmd --cluster check $1:$REDIS_PORT
}

# checkForAllAgree(){
#   local checkResponse retCode=0
#   checkResponse="$(getRedisCheckResponse $1 || retCode=$?)"
#   [[ "$checkResponse" == *"OK] All nodes agree about slots configuration."* ]]
#   [[ "$checkInfo" != *"Nodes don't agree about configuration"* ]]
#   return $retCode
# }

checkForAllAgree(){
  local checkResponse retCode=0
  checkResponse="$(runRedisCmd -h $1 cluster nodes || retCode=$?)"
  cnt=$(echo "$checkResponse" | grep -c 'connected')
  ids=$(echo "$checkResponse" | grep master | grep 'connected$' | awk '{print $1}')
  local excludedCnt=0
  if [ -n "$LEAVING_REDIS_NODES" ]; then
    if echo "$LEAVING_REDIS_NODES" | grep 'master'; then
      local id; for id in $ids; do
        excludedCnt=$((excludedCnt+$(echo "$checkResponse" | grep $id | wc -l)))
      done
    else
      excludedCnt=$(echo $LEAVING_REDIS_NODES|xargs -n1 | wc -l)
    fi
  fi
  log "check nodes status: ready $cnt, excluded $excludedCnt, want $2"
  test $((cnt-excludedCnt)) -eq $2
}


checkAllAddSuccess(){
  local ip checkResponse retCode=0 newIP=$1
  shift 1;
  for ip in $@ ;do
    checkResponse="$(runRedisCmd -h $ip cluster nodes || retCode=$?)"
    [[ "$checkResponse" == *" $newIP:$REDIS_PORT@"* ]]
  done
}


waitUntilAllNodesIsOk(){
  local ip ips=$@
  local sum=$(echo $ips|xargs -n1 | wc -l)
  for ip in $(echo $ips|xargs -n1);do
    log --debug "check node $ip"
    retry 120 1 0 checkRedisStateIsOkByInfo $ip
    retry 600 1 0 checkForAllAgree $ip $sum
  done
}

getStableNodesIps(){
  unstableNodes=$(echo "$LEAVING_REDIS_NODES $JOINING_REDIS_NODES" | sed 's/^[ \t]*//; s/[ \t]*$//; s/[ \t]+/ /g')
  echo "$REDIS_NODES" | awk -F' ' '
  BEGIN {
      if (length("'"$unstableNodes"'") > 0) {
          split("'"$unstableNodes"'", ignored_words, " ")
          for (i in ignored_words) {
              if (ignored_words[i] != "") {
                  ignored[ignored_words[i]] = 1
              }
          }
      }
  }
  {
      for (i = 1; i <= NF; i++) {
          if (!($i in ignored)) {
              split($i, fields, "/")
              print fields[5]
          }
      }
  }'
}

getFirstNodeIpInStableNodesExceptLeavingNodes(){
  unstableNodes=$(echo "$LEAVING_REDIS_NODES $JOINING_REDIS_NODES" | sed 's/^[ \t]*//; s/[ \t]*$//; s/[ \t]+/ /g')
  echo "$REDIS_NODES" | awk -F' ' '
  BEGIN {
      if (length("'"$unstableNodes"'") > 0) {
          split("'"$unstableNodes"'", ignored_words, " ")
          for (i in ignored_words) {
              if (ignored_words[i] != "") {
                  ignored[ignored_words[i]] = 1
              }
          }
      }
  }
  {
      for (i = 1; i <= NF; i++) {
          if (!($i in ignored)) {
              split($i, fields, "/")
              print fields[5]
              exit 0
          }
      }
  }'
}

getParentNodeId() {
  echo $NODE_GROUPS= | tr ' ' '\n' | grep ":$1" | cut -d':' -f1
}

getFirstNodeIdInStableNodesExceptLeavingNodes(){
    unstableNodes=$(echo "$LEAVING_REDIS_NODES $JOINING_REDIS_NODES" | sed 's/^[ \t]*//; s/[ \t]*$//; s/[ \t]+/ /g')
  echo "$REDIS_NODES" | awk -F' ' '
  BEGIN {
      if (length("'"$unstableNodes"'") > 0) {
          split("'"$unstableNodes"'", ignored_words, " ")
          for (i in ignored_words) {
              if (ignored_words[i] != "") {
                  ignored[ignored_words[i]] = 1
              }
          }
      }
  }
  {
      for (i = 1; i <= NF; i++) {
          if (!($i in ignored)) {
              split($i, fields, "/")
              print fields[4]
              exit 0
          }
      }
  }'
}

findMasterIdByJoiningSlaveIp(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  local gid; gid="$(echo "$REDIS_NODES" |xargs -n1 |grep -E "/${1//\./\\.}$" |cut -d "/" -f1)"
  local ipsInGid; ipsInGid="$(echo "$REDIS_NODES" |xargs -n1 |awk -F "/" 'BEGIN{ORS="|"}{if ($1=='$gid' && $5!~/^'${1//\./\\.}'$/){print $5}}' |sed 's/\./\\./g')"
  local redisClusterNodes; redisClusterNodes="$(runRedisCmd -h "$firstNodeIpInStableNode" cluster nodes)"
  log "redisClusterNodes:  $redisClusterNodes"
  local masterId; masterId="$(echo "$redisClusterNodes" |awk '$0~/.*('${ipsInGid:0:-1}'):'$REDIS_PORT'.*(master){1}.*/{print $1}')"
  local masterIdCount; masterIdCount="$(echo "$masterId" |wc -l)"
  if [[ $masterIdCount == 1 ]]; then
    echo "$masterId"
  else
    log "node ${1?slaveIp is required} get $masterIdCount masterId:'$masterId'";return 1
  fi
}

getRedisRole(){
  local result; result="$(runRedisCmd -h $1 role)"
  echo "$result" |head -n1
}

sortOutLeavingNodesIps(){
  local slaveNodeIps="" masterNodeIps=""
  local node; for node in $LEAVING_REDIS_NODES;do
    local nodeRole; nodeRole="$(getRedisRole ${node##*/})"
    if [[ "$nodeRole" == "master" ]]; then
      masterNodeIps="$masterNodeIps ${node##*/}"
    else
      slaveNodeIps="$slaveNodeIps ${node##*/}"
    fi
  done
  echo "$slaveNodeIps $masterNodeIps" |xargs -n1
}

checkClusterPort() {
  if [[ ${CONFIG_CLUSTER_PORT} != 0 ]];then
    return
  elif [ "${REDIS_TLS_CLUSTER}" == "yes" ] && [ "${REDIS_TLS_PORT}" == "0" ] ;then
    log "TLS-Cluster=yes and tls-port=0 will execute the error, Code:(${CLUSTER_CLUSER_TLS_PORT_ERR})"
    return ${CLUSTER_CLUSER_TLS_PORT_ERR}
  elif [ "${REDIS_TLS_CLUSTER}" == "no" ] && [ "${REDIS_PORT}" == "0" ] ;then
    log "TLS-Cluster=no and port=0 will execute the error, Code:(${CLUSTER_CLUSER_PORT_ERR})"
    [ "${REDIS_PLAIN_PORT}" != "0" ] || return ${CLUSTER_CLUSER_PORT_ERR}
  fi
}

preScaleOut(){
  log "preScaleOut"
  checkClusterPort
  return 0
}

clusterAddNode() {
  if ! runRedisCmd --timeout 120 -h "$2" --cluster add-node ${1##*/}:$REDIS_PORT $2:$REDIS_PORT >> $logFile; then
    return 1
  fi
  return 0
}

clusterRebalance() {
  if ! runRedisCmd --timeout 86400 -h $1 --cluster rebalance --cluster-use-empty-masters $1:$REDIS_PORT >> $logFile; then
    log "ERROR failed to rebalance the cluster ($?)."
    return 1
  fi
  return 0
}

scaleOut() {
  local logFile=/data/appctl/logs/preScaleIn.$(date +%s).$$.log
  rotate $NODE_CONF_FILE
  log "joining nodes $JOINING_REDIS_NODES"
  [[ -n "$JOINING_REDIS_NODES" ]] || {
    log "no joining nodes detected"
    return $NO_JOINING_NODES_DETECTED_ERR
  }

  #runRedisCmd cluster nodes | awk -F "[ :]+" '{print $2}'
  # add master nodes
  local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  local node; for node in $JOINING_REDIS_NODES;do
    if [[ "$(echo "$node"|cut -d "/" -f3)" == "master" ]];then
      waitUntilAllNodesIsOk "$stableNodesIps"
      log "add master node ${node##*/}"
      retry 120 2 0 clusterAddNode $node $firstNodeIpInStableNode
      retry 120 1 0 checkAllAddSuccess "${node##*/}" "$stableNodesIps" 
      log "add master node ${node##*/} end"
      stableNodesIps="$(echo "$stableNodesIps ${node##*/}")"
    fi
  done
  # wait 5s for new nodes discovery
  sleep 5
  # rebalance slots
  log "check stableNodesIps: $stableNodesIps"
  waitUntilAllNodesIsOk "$stableNodesIps"
  log "== rebalance start =="
  # 在配置未同步完的情况下，会出现 --cluster-use-empty-masters 未生效的情况
  retry 120 2 0 clusterRebalance $firstNodeIpInStableNode
  log "== rebanlance end =="
  log "check stableNodesIps: $stableNodesIps"
  waitUntilAllNodesIsOk "$stableNodesIps"
  # add slave nodes
  local node; for node in $JOINING_REDIS_NODES;do
    if [[ "$(echo "$node"|cut -d "/" -f3)" == "slave" ]];then
      log "add master-replica node ${node##*/}"
      waitUntilAllNodesIsOk "$stableNodesIps"
      # 新增的从节点在短时间内其在配置文件中的身份为 master，会导致再次增加从节点时获取到的 masterId 为多个，这里需要等到 masterId 为一个为止 
      local masterId; masterId="$(retry 20 1 0 findMasterIdByJoiningSlaveIp ${node##*/})"
      log "${node##*/}: masterId is $masterId"
      runRedisCmd --timeout 120 -h "$firstNodeIpInStableNode" --cluster add-node ${node##*/}:$REDIS_PORT $firstNodeIpInStableNode:$REDIS_PORT --cluster-slave --cluster-master-id $masterId >> $logFile
      log "add master-replica node ${node##*/} end"
      stableNodesIps="$(echo "$stableNodesIps ${node##*/}")"
    fi
  done
}

getMyIdByMyIp(){
  runRedisCmd -h ${1?my ip is required} CLUSTER MYID
}

resetMynode(){
  local nodeIp; nodeIp="$1"
  local resetResult; resetResult="$(runRedisCmd -h $nodeIp CLUSTER RESET)"
  if [[ "$resetResult" == "OK" ]]; then
    log "Reset node $nodeIp successful"
  else 
    log "ERROR to reset node $nodeIp fail"
    return $CLUSTER_RESET_ERR
  fi
}

# 仅在删除主从节点对时调用
checkMemoryIsEnoughAfterScaled(){
  log "checkMemoryIsEnoughAfterScaled"
  local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
  local allUsedMemory; allUsedMemory=0
  # 判断节点中是否存在内存使用率达到 0.95 的，存在便禁止删除
  local stableNodeIp; for stableNodeIp in $stableNodesIps; do
    local rawMemoryInfo; rawMemoryInfo="$(runRedisCmd -h $stableNodeIp INFO MEMORY)"
    local usedMemory; usedMemory="$(echo "$rawMemoryInfo" |awk -F":" '{if($1=="used_memory"){printf $2}}')"
    local maxMemory; maxMemory="$(echo "$rawMemoryInfo" |awk -F":" '{if($1=="maxmemory"){printf $2}}')"
    local memoryUsage; memoryUsage="$(awk 'BEGIN{printf "%.3f\n",'$usedMemory'/'$maxMemory'}')"
    [[ $memoryUsage > 0.95 ]] && (log "node $stableNodeIp memoryUsage > 0.95, actual value: $memoryUsage, forbid scale in"; return $EXISTS_REDIS_MEMORY_USAGE_TOO_BIG)
    allUsedMemory="$(awk 'BEGIN{printf '$usedMemory'+'$allUsedMemory'}')"
  done
  # 判断节点被删除后剩余节点的平均内存使用率是否达到 0.95，满足即禁止删除
  local nodesIpsAfterScaleIn; nodesIpsAfterScaleIn="$(getStableNodesIps)"
  local nodesCountAfterScaleIn; nodesCountAfterScaleIn="$(echo "$nodesIpsAfterScaleIn" |xargs -n 1|wc -l)"
  local averageMemoryUsageAfterScaleIn; averageMemoryUsageAfterScaleIn="$(awk 'BEGIN{printf "%.3f\n",'$allUsedMemory'/'$maxMemory'/'$nodesCountAfterScaleIn'}')"
  [[ $averageMemoryUsageAfterScaleIn > 0.95 ]] && (log " averageMemoryUsage > 0.95, calculated result: $averageMemoryUsageAfterScaleIn, forbid scale in"; return $AVERAGE_REDIS_MEMORY_USAGE_TOO_BIG_AFTER_SCALEIN)
  log "RedisMemoryIsOk"
  return 0
}

checkRealForget(){
  local checkResponse retCode=0
  checkResponse="$(runRedisCmd -h $1 cluster nodes || retCode=$?)"
  if echo "$checkResponse" | grep "$2"; then
    log "still remember node $2, from $1"
    return 1
  fi
  log "really forgot node $2, from $1"
  return 0
}

waitUntilAllNodesForget() {
  local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
  local sip; for sip in $stableNodesIps; do
    retry 600 1 0 checkRealForget $sip $1
  done
}

# redis-cli --cluster rebalance --weight xxx=0 yyy=0
preScaleIn() {
  checkClusterPort
  local logFile=/data/appctl/logs/preScaleIn.$(date +%s).$$.log
  rotate $NODE_CONF_FILE
  log "leaving nodes $LEAVING_REDIS_NODES"
  log "getFirstNodeIpInStableNode"
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  log "firstNodeIpInStableNode: $firstNodeIpInStableNode"
  log "getStableNodesIps"
  local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
  log "stableNodesIps: $stableNodesIps"
  log "get runtimeMasters"
  local runtimeMasters
  runtimeMasters="$(runRedisCmd -h "$firstNodeIpInStableNode" --cluster info $firstNodeIpInStableNode $REDIS_PORT | awk '$3=="->" {print gensub(/:.*$/, "", "g", $1)}' | paste -s -d'|')"
  log "runtimeMasters: $runtimeMasters"
  log "get runtimeMastersToLeave"
  # 防止 egrep 未匹配到信息而报错，比如在删除所有 master-replica 节点时，该位置匹配不到导致删除失败
  local runtimeMastersToLeave; runtimeMastersToLeave="$(echo $LEAVING_REDIS_NODES | xargs -n1 | egrep "(${runtimeMasters//\./\\.})$" | xargs)" || true
  log "runtimeMastersToLeave: $runtimeMastersToLeave"
  if [[ "$LEAVING_REDIS_NODES" == *"/master/"* ]]; then
    checkMemoryIsEnoughAfterScaled
    local totalCount; totalCount="$(echo "$runtimeMasters" | awk -F"|" '{printf NF}')"
    local leavingCount; leavingCount="$(echo "$runtimeMastersToLeave" | awk '{printf NF}')"
    #(( $leavingCount>0 && $totalCount-$leavingCount>2 )) || (log "ERROR broken cluster: runm='$runtimeMasters' leav='$LEAVING_REDIS_NODES'."; return $NUMS_OF_REMAIN_NODES_TOO_LESS_ERR)
    log "== rebalance start =="
    local leavingIds node; leavingIds="$(for node in $runtimeMastersToLeave; do getMyIdByMyIp ${node##*/}; done)"
    runRedisCmd --timeout 86400 -h "$firstNodeIpInStableNode" --cluster rebalance --cluster-weight $(echo $leavingIds | xargs -n1 | sed 's/$/=0/g' | xargs) $firstNodeIpInStableNode:$REDIS_PORT >> $logFile || {
      log "ERROR failed to rebalance the cluster ($?)."
      return $REBALANCE_ERR
    }
    log "== rebalance end =="
    log "== check start =="
    waitUntilAllNodesIsOk "$stableNodesIps"
    log "check end"
  else
    [ -z "$runtimeMastersToLeave" ] || (log "ERROR replica node(s) '$runtimeMastersToLeave' are now runtime master(s)."; return $DELETED_REPLICA_NODE_REDIS_ROLE_IS_MASTER_ERR)
  fi

  # cluster forget leavingNode from RedisNode
  # Make sure that forget slave node before master node is forgotten
  local leavingNodeIps; leavingNodeIps="$(sortOutLeavingNodesIps)"
  local leavingNodeIp; for leavingNodeIp in $leavingNodeIps; do
    log "forget $leavingNodeIp"
    local leavingNodeId; leavingNodeId="$(getMyIdByMyIp $leavingNodeIp)"
    local node nodeIp; for node in $REDIS_NODES; do
      nodeIp=${node##*/}
      if echo "$stableNodesIps" | grep -E "^${nodeIp//\./\\.}$" |grep -Ev "^${leavingNodeIp//\./\\.}$"; then
        log "forget in ${nodeIp}"
        runRedisCmd -h ${nodeIp} cluster forget $leavingNodeId || (log "ERROR failed to delete '${leavingNodeIp}':'$leavingNodeId' ($?)."; return $CLUSTER_FORGET_ERR)    
      fi
    done
    log "forget $leavingNodeIp end"
    resetMynode $leavingNodeIp
    waitUntilAllNodesForget $leavingNodeIp
  done
}

scaleIn(){
  true
}

clearDisk() {
  find /data/redis/ -maxdepth 1 -type f -mtime +3 -regex "/data/redis/temp-rewriteaof-[0-9]+.aof" -delete
}

check(){
  _check
  local loadingTag="loading the dataset in memory"
  local infoResponse;infoResponse="$(runRedisCmd cluster info)"
  [[ "$infoResponse" == *"$loadingTag"* ]] && return 0
  [[ "$infoResponse" == *"cluster_state:ok"* ]] || return $CLUSTER_STATE_NOT_OK
  # 是否发生错位
  checkGroupMatched
  checkClusterMatched
  clearDisk
}

checkBgsaveDone(){
  local lastsaveCmd; lastsaveCmd="$(getRuntimeNameOfCmd "LASTSAVE")"
  [[ $(runRedisCmd $lastsaveCmd) > ${1?Lastsave time is required} ]]
}

checkBgrewriteofDone() {
  local persistenceRaw=$(runRedisCmd INFO persistence)
  if ! echo "$persistenceRaw" | grep -Eq "aof_rewrite_in_progress: ?0"; then
    log "aof_rewrite is still in progress"
    return 1
  fi
  if ! echo "$persistenceRaw" | grep -Eq "aof_rewrite_scheduled: ?0"; then
    log "aof_rewrite is scheduled but not running"
    return 1
  fi
  log "aof_rewrite is done"
  return 0
}

backup(){
  log "Start backup"
  local lastsave="LASTSAVE" bgsave="BGSAVE"
  local lastsaveCmd bgsaveCmd; lastsaveCmd="$(getRuntimeNameOfCmd $lastsave)" bgsaveCmd="$(getRuntimeNameOfCmd $bgsave)"
  local lastTime; lastTime="$(runRedisCmd $lastsaveCmd)"
  runRedisCmd $bgsaveCmd
  retry 60 1 $EC_BACKUP_ERR checkBgsaveDone $lastTime
  log "backup successfully"
}

reload() {
  # 避免集群刚创建时执行 reload_cmd
  if ! isNodeInitialized; then return 0;fi

  if [[ "$1" == "redis-server" ]]; then
    # redis.conf 发生改变时可以对 redis 做重启操作，防止添加节点时redis-server 重启
    if checkFileChanged "$CHANGED_CONFIG_FILE $CHANGED_ACL_FILE $(echo $TLS_CONF_LIST | xargs -n1 | cut -f 1 -d:)"; then 
      stopSvc "redis-server"
      configure
      startSvc "redis-server"
    fi
    return 0
  fi
  _reload $@
}

revive(){
  [[ "${REVIVE_ENABLED:-"true"}" == "true" ]] || return 0
  # 是否发生错位
  if !checkGroupMatched; then
    _revive
    return 0
  fi
  checkClusterMatched || :
  _revive
}

findMasterIpByNodeIp(){
  local myRoleResult myRole nodeIp=${1:-$MY_IP}
  myRoleResult="$(runRedisCmd -h $nodeIp info Replication)"
  myRole="$(echo "$myRoleResult" |awk -F "[:\r]+" '$1=="role"{print $2}')"
  if [[ "$myRole" == "master" ]]; then
    echo "$nodeIp"
  else
    echo "$myRoleResult" | awk -F "[:\r]+" '$1=="master_host"{print $2}'
  fi
}

measure() {
  local groupMatched; groupMatched="$(getGroupMatched)"
  local masterIp replicaDelay
  masterIp="$(findMasterIpByNodeIp)"
  if [[ "$masterIp" != "$MY_IP" ]]; then
    local masterReplication masterOffset myOffset
    masterReplication="$(runRedisCmd -h "${masterIp}" info replication)"
    masterOffset="$(echo "$masterReplication"|grep "master_repl_offset" |cut -d: -f2 |tr -d '\n\r')"
    myOffset=$(echo "$masterReplication" |grep -E "ip=${MY_IP//\./\\.}\,"| cut -d, -f4 |cut -d= -f2|tr -d '\n\r')
    replicaDelay="$((masterOffset-myOffset))"
  else
    replicaDelay=0
  fi

  runRedisCmd info all | awk -F: '{
    if($1~/^(cmdstat_|connected_c|db|evicted_|keyspace_|total_conn)/) {
      r[$1] = gensub(/^(keys=|calls=)?([0-9]+).*/, "\\2", 1, $2);
    }else if($1~/^(mem_fragmentation_ratio|instantaneous_ops_per_sec|loading|aof_buffer_length|aof_rewrite_in_progress|rdb_bgsave_in_progress|master_sync_in_progress|repl_backlog_size|repl_backlog_histlen|maxmemory|role|used_memory)$/) {
      r[$1] = gensub(/\r$/, "", 1, $2)
    }
  }
  END {
    for(k in r) {
      if(k~/^cmdstat_/) {
        cmd = gensub(/^cmdstat_/, "", 1, k)
        m[cmd] += r[k]
      } else if(k~/^db[0-9]+/) {
        m["key_count"] += r[k]
      }
    }
    m["connected_clients"] = r["connected_clients"]
    m["maxmemory"] = r["maxmemory"]
    m["total_connections_received"] = r["total_connections_received"]
    m["used_memory"] = r["used_memory"]
    m["node_role"] = r["role"]
    m["evicted_keys"] = r["evicted_keys"]
    m["keyspace_misses"] = r["keyspace_misses"]
    m["keyspace_hits"] = r["keyspace_hits"]
    m["expired_keys"] = r["expired_keys"]
    m["loading"] = r["loading"]
    m["rdb_bgsave"] = r["rdb_bgsave_in_progress"]
    m["aof_rewrite"] = r["aof_rewrite_in_progress"]
    m["master_sync"] = r["master_sync_in_progress"]
    memUsage = r["maxmemory"] ? 10000 * r["used_memory"] / r["maxmemory"] : 0
    m["memory_usage_min"] = m["memory_usage_avg"] = m["memory_usage_max"] = memUsage
    totalOpsCount = r["keyspace_hits"] + r["keyspace_misses"]
    m["hit_rate_min"] = m["hit_rate_avg"] = m["hit_rate_max"] = totalOpsCount ? 10000 * r["keyspace_hits"] / totalOpsCount : 10000
    m["connected_clients_min"] = m["connected_clients_avg"] = m["connected_clients_max"] = r["connected_clients"]
    m["repl_backlog_avg"] = m["repl_backlog_max"] = m["repl_backlog_min"] = r["repl_backlog_histlen"] / r["repl_backlog_size"] * 10000
    m["aof_buffer_avg"] = m["aof_buffer_max"] = m["aof_buffer_min"] = r["aof_buffer_length"] ? r["aof_buffer_length"] : 0
    m["mem_fragmentation_ratio_avg"] = m["mem_fragmentation_ratio_max"] = m["mem_fragmentation_ratio_min"] = r["mem_fragmentation_ratio"] ? r["mem_fragmentation_ratio"] * 100 : 100
    m["instantaneous_ops_per_sec_avg"] = m["instantaneous_ops_per_sec_max"] = m["instantaneous_ops_per_sec_min"] = r["instantaneous_ops_per_sec"]
    m["group_matched"] = "'$groupMatched'"
    m["replica_delay"] = "'$replicaDelay'"
    for(k in m) {
      print k FS m[k]
    }
  }' | jq -R 'split(":")|{(.[0]):.[1]}' | jq -sc add || ( local rc=$?; log "Failed to measure Redis: $metrics"; return $rc )
}

redisCli() {
  local authOpt; [ -z "$REDIS_PASSWORD" ] || authOpt="--no-auth-warning -a $REDIS_PASSWORD"
  [[ "$REDIS_TLS_PORT" == "${REDIS_PORT}" ]] && tls="--tls"
  echo "/opt/redis/current/redis-cli $authOpt $tls --cert /data/redis/tls/redis.crt --key /data/redis/tls/redis.key --cacert /data/redis/tls/ca.crt -p $REDIS_PORT $@"
}

redisCli2() {
  local authOpt; [ -z "$REDIS_PASSWORD" ] || authOpt="--no-auth-warning -a '$REDIS_PASSWORD'"
  [[ "$REDIS_TLS_PORT" == "${REDIS_PORT}" ]] && tls="--tls"
  echo "/opt/redis/current/redis-cli $authOpt $tls --cert /data/redis/tls/redis.crt --key /data/redis/tls/redis.key --cacert /data/redis/tls/ca.crt -p $REDIS_PORT $@"
}

runRedisCmd() {
  local not_error="getUserList addUser measure runRedisCmd"
  local timeout=5; if [ "$1" == "--timeout" ]; then timeout=$2; shift 2; fi
  local result retCode=0
  result="$(timeout --preserve-status ${timeout}s $(redisCli) $@  2>&1)" || retCode=$?
  if [ "$retCode" != 0 ] || [[ " $not_error " != *" $cmd "* && "$result" == *ERR* ]]; then
    log "ERROR failed to run redis command '$@' ($retCode): $(echo "$result" |tr '\r\n' ';' |tail -c 4000)."
    retCode=$REDIS_COMMAND_EXECUTE_FAIL
  else
    echo "$result"
  fi
  return $retCode
}

getRuntimeNameOfCmd() {
  node_id=${PARENT_NODE_ID}
  if [[ "$1" == "--node-id" ]]; then  node_id=$2; shift 2; fi
  if [[ "$DISABLED_COMMANDS" == *"$1"* ]];then
    echo -n "${CLUSTER_ID}${node_id}${1}" | md5sum | cut -f 1 -d " "
  else
    echo $1
  fi
}


swapIpAndName() {
  local fields replaceCmd  port=$REDIS_PLAIN_PORT nodes=$REDIS_NODES
  [[ "$REDIS_TLS_CLUSTER" == "yes" ]] && port=$REDIS_TLS_PORT
  sudo -u redis touch $NODE_CONF_FILE && rotate $NODE_CONF_FILE
  if [ -n "$1" ];then
    nodes="$UPDATE_CHANGE_VXNET $nodes"
    fields='{print "s/ "$4":[0-9]*@[0-9]*/ "$5":'$port'@'${CLUSTER_PORT}'/g"}'
  else
    fields='{gsub("\\.", "\\.", $5);{print "s/ "$5":[0-9]*@[0-9]*/ "$4":'$port'@'${CLUSTER_PORT}'/g"}}'
  fi
  replaceCmd="$(echo "$nodes" | xargs -n1 | awk -F/ "$fields"  | paste -sd';');s/:[0-9]*@[0-9]* /:$port@${CLUSTER_PORT} /g"
  sed -i "$replaceCmd" $NODE_CONF_FILE
}

# trim a line
# be sure only one blank exists when blanks present in the middle of a line
formatConf() {
  lines=$(cat $1)
  lines=$(echo "$lines" | sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
  lines=$(echo "$lines" | sed -e 's/[[:space:]]+/ /g')
  echo "$lines"
}

mergeRedisConf() {
  log "mergeRedisConf: start"
  if [ ! -f $RUNTIME_CONFIG_FILE ]; then
    log "mergeRedisConf: first create, end"
    formatConf $RUNTIME_CONFIG_FILE_TMP > $RUNTIME_CONFIG_FILE
    chown redis:svc $RUNTIME_CONFIG_FILE
    return
  fi

  format_config_tmp=$(formatConf $RUNTIME_CONFIG_FILE_TMP)
  echo "$format_config_tmp" > $RUNTIME_CONFIG_FILE_COOK
  format_config_run=$(formatConf $RUNTIME_CONFIG_FILE)
  echo "$format_config_run" >> $RUNTIME_CONFIG_FILE_COOK
  combine_config=$(awk '!seen[$0]++' $RUNTIME_CONFIG_FILE_COOK)
  echo "$combine_config" > $RUNTIME_CONFIG_FILE_COOK

  awk '
  {
      first_word = $1
      
      if ($1 == "client-output-buffer-limit" || $1 == "rename-command") {
          first_two_words = $1 " " $2
      } else {
          first_two_words = $1
      }
      
      if (!seen[first_two_words]) {
          seen[first_two_words] = $0
          if (first_two_words != "client-output-buffer-limit slave") {
              print $0
          }
      }
  }
  ' $RUNTIME_CONFIG_FILE_COOK > $RUNTIME_CONFIG_FILE
  log "mergeRedisConf: end"
}

mergeRedisConf2() {
  log "mergeRedisConf: start"
  if [ ! -f $RUNTIME_CONFIG_FILE ]; then
    log "mergeRedisConf: first create, end"
    formatConf $RUNTIME_CONFIG_FILE_TMP > $RUNTIME_CONFIG_FILE
    chown redis:svc $RUNTIME_CONFIG_FILE
    return
  fi
  
  # keys from tmp
  log "keys from tmp"
  format_config_tmp=$(formatConf $RUNTIME_CONFIG_FILE_TMP)
  keys_config_tmp=($(echo "$format_config_tmp" | grep -v "client-output-buffer-limit\|rename-command" | awk '{print $1}' | sort -u))
  dkeys=$(echo "$format_config_tmp" | grep "client-output-buffer-limit\|rename-command" | awk '{print $1 " " $2}' | sort -u)
  while IFS= read -r line; do
        keys_config_tmp+=("$line")
  done <<< "$dkeys"
  
  # keys from run
  log "keys from run"
  format_config_run=$(formatConf $RUNTIME_CONFIG_FILE)
  keys_config_run=($(echo "$format_config_run" | grep -v "client-output-buffer-limit\|rename-command" | awk '{print $1}' | sort -u))
  dkeys=$(echo "$format_config_run" | grep "client-output-buffer-limit\|rename-command" | awk '{print $1 " " $2}' | sort -u)
  while IFS= read -r line; do
        keys_config_run+=("$line")
  done <<< "$dkeys"

  # merge
  log "merge start"
  for key in "${keys_config_tmp[@]}"; do
    line=$(echo "$format_config_tmp" | sed -n "/^$key\ / {p;q;}")
    # char '&' must be replaced by '\&': it's a special char to sed
    line="${line//&/\\&}"
    if ! echo " ${keys_config_run[*]} " | grep "\s\+${key}\s\+"; then
      # log "append new config: $line"
      format_config_run=$(echo "$format_config_run" | sed '$a'" $line")
    else
      # log "modify config: $line"
      format_config_run=$(echo "$format_config_run" | sed "0,\|^$key\ .*|s||$line|")
    fi
  done
  log "merge end"

  # acl
  log "acl"
  if [ "$ENABLE_ACL" = "no" ]; then
    log "remove acl config from redis.conf, because acl is disabled"
    format_config_run=$(echo "$format_config_run" | sed "/^aclfile\ .*/d")
  fi

  echo "$format_config_run" > $RUNTIME_CONFIG_FILE
  log "mergeRedisConf: end"
}

configureForRedis(){
  log "configureForRedis Start"
  awk '$0~/^[^ #$]/ ? $1~/^(client-output-buffer-limit|rename-command)$/ ? !a[$1$2]++ : !a[$1]++ : 0' \
    $CHANGED_CONFIG_FILE $DEFAULT_CONFIG_FILE $RUNTIME_CONFIG_FILE_TMP.1 > $RUNTIME_CONFIG_FILE_TMP
  log "configureForRedis End"

  mergeRedisConf
}

rotateTLS() {
  local tlsConf changedConf runtimeConf
  for tlsConf in $TLS_CONF_LIST; do
    changedConf="${tlsConf%:*}"
    runtimeConf="${tlsConf#*:}"
    rotate $runtimeConf
    cat $changedConf > $runtimeConf
  done
}

combineACL() {
  cat $CHANGED_ACL_FILE $RUNTIME_ACL_FILE > $RUNTIME_ACL_FILE_COOK
  awk '
  {
      username = $2
      
      if (!seen[username]) {
          seen[username] = $0
          print $0
      }
  }
  ' $RUNTIME_ACL_FILE_COOK > $RUNTIME_ACL_FILE
}

configureForACL() {
  log "configureForACL Start"
  if [[ "$ENABLE_ACL" == "no" && -e "$ACL_CLEAR" ]] ; then
    rm $ACL_CLEAR -f
    combineACL
  elif [[ "$ENABLE_ACL" == "yes" ]]; then
    if [[ -e "$ACL_CLEAR" ]];then
      cat $CHANGED_ACL_FILE > $RUNTIME_ACL_FILE
      awk '$2!="default"' $RUNTIME_ACL_FILE.1 >> $RUNTIME_ACL_FILE
    else
      cat $CHANGED_ACL_FILE > $RUNTIME_ACL_FILE
      sudo -u redis touch $ACL_CLEAR
    fi
  elif [[ "$ENABLE_ACL" == "no" ]]; then
    cat $CHANGED_ACL_FILE > $RUNTIME_ACL_FILE
    awk '$2!="default"' $RUNTIME_ACL_FILE.1 >> $RUNTIME_ACL_FILE
  fi
  log "configureForACL End"
}

updatePorts() {
  # update ports settings in node-6379.conf in case the ports changed
  local fields replaceCmd  port=$REDIS_PLAIN_PORT nodes=$REDIS_NODES
  [[ "$REDIS_TLS_CLUSTER" == "yes" ]] && port=$REDIS_TLS_PORT
  replaceCmd="s/:[0-9]*@[0-9]*/:$port@${CLUSTER_PORT}/g"
  sed -i "$replaceCmd" $NODE_CONF_FILE
}

configure() {
  sudo -u redis touch $RUNTIME_CONFIG_FILE_TMP
  rotate $RUNTIME_ACL_FILE
  rotate $RUNTIME_CONFIG_FILE_TMP
  swapIpAndName --reverse
  updatePorts
  configureForACL
  configureForRedis
  rotateTLS
}

checkFileChanged() {
  local configFile retCode=1
  for configFile in $@ ; do
    [ -f "$configFile.1" ] && cmp -s $configFile $configFile.1 || retCode=0
  done
  return $retCode
}

runCommand(){
  local myRole; myRole="$(getRedisRole $MY_IP)"
  if [[ "$myRole" != "master" ]]; then log "My role is not master, Unauthorized operation";return 0;fi 
  local sourceCmd params maxTime; sourceCmd="$(echo $1 |jq -r .cmd)" \
        params="$(echo $1 |jq -r .params)" maxTime=$(echo $1 |jq -r .timeout)
  local cmd; cmd="$(getRuntimeNameOfCmd $sourceCmd)"
  if [[ "$sourceCmd" == "BGSAVE" ]];then
    log "runCommand BGSAVE"
    backup
  else
    runRedisCmd --timeout $maxTime $cmd $params
  fi
}

getRedisRoles(){
  local firstNodeIpInStableNode; firstNodeIpInStableNode="$(getFirstNodeIpInStableNodesExceptLeavingNodes)"
  log "firstNodeIpInStableNode: $firstNodeIpInStableNode"
  local rawResult; rawResult="$(runRedisCmd -h "$firstNodeIpInStableNode" cluster nodes)"
  local loadingTag="loading the dataset in memory"
  [[ "$rawResult" == *"$loadingTag"* ]] && return 0
  local firstProcessResult; firstProcessResult="$(echo "$rawResult" |awk 'BEGIN{OFS=","} {split($2,ips,":");print "\""ips[1]"\"","\""gensub(/^(myself,)?(master|slave|fail|pfail){1}.*/,"\\2",1,$3)"\"","\""$4"t""\""}' |sort -t "," -k3)"
  local regexpResult; regexpResult="$(echo "$rawResult" |awk 'BEGIN{ORS=";"}{split($2,ips,":");print "s/"$1"t/"ips[1]"/g"}END{print "s/-t/None/g"}')"
  local secondProcssResult; secondProcssResult="$(echo "$firstProcessResult" |sed "$regexpResult" |awk 'BEGIN{printf "["}{a[NR]=$0}END{for(x in a){printf x==NR ? "["a[x]"]" : "["a[x]"],"};printf "]"}')"
  echo "$secondProcssResult" |jq -c '{"labels":["ip","role","master_ip"],"data":.}'
}

getGroupMatched(){
  local clusterNodes port="($REDIS_PLAIN_PORT|$REDIS_TLS_PORT)" groupMatched="true" targetIp="${1:-$MY_IP}"
  if [[ "$targetIp" == "$MY_IP" ]]; then
    if checkActive "redis-server"; then
      clusterNodes="$(runRedisCmd CLUSTER NODES)"
    else
      clusterNodes="$(cat $NODE_CONF_FILE)"
    fi
  else
    clusterNodes="$(runRedisCmd -h "$targetIp" CLUSTER NODES)"
  fi

  local targetRoleInfo; targetRoleInfo="$(echo "$clusterNodes" |awk 'BEGIN{OFS=" "}{if($0~/'${targetIp//\./\\.}':'$port'/){print $3,$4}}')"
  local targetRole; targetRole="$(echo "$targetRoleInfo"|awk '{split($1,role,",");print role[2]}')"
  if [[ "$targetRole" == "slave" ]]; then
      local targetMasterId; targetMasterId="$(echo "$targetRoleInfo" |awk '{print $2}')"
      local targetMasterIp; targetMasterIp="$(echo "$clusterNodes" |awk '{if ($1~/'$targetMasterId'/){split($2,ips,":");print ips[1]}}')"
      local ourGid; ourGid="$(echo "$REDIS_NODES" |xargs -n1 |grep -E "/(${targetMasterIp//\./\\.}|${targetIp//\./\\.})$" |cut -d "/" -f1 |uniq)"
      [[ $(echo "$ourGid" |awk '{print NF}') == 1 ]] || {
        log --debug "clusterNodes for $targetIp dismatched group: 
        $clusterNodes
        "
        groupMatched="false"
      }
  fi
  echo $groupMatched
}

getClusterMatched(){
  local clusterNodes port="($REDIS_PLAIN_PORT|$REDIS_TLS_PORT)" clusterMatched="true" targetIp="${1:-$MY_IP}"
  if [[ "$targetIp" == "$MY_IP" ]]; then
    if checkActive "redis-server"; then
      clusterNodes="$(runRedisCmd CLUSTER NODES)"
    else
      clusterNodes="$(grep -v '^vars currentEpoch' $NODE_CONF_FILE)"
    fi
  else
    clusterNodes="$(runRedisCmd -h "$targetIp" CLUSTER NODES)"
  fi

  local expectedNodes; expectedNodes="("
  local node; for node in $REDIS_NODES; do
    node="${node##*/}"
    expectedNodes="$expectedNodes${node//\./\\.}:$port|"
  done
  expectedNodes="${expectedNodes%|*})"
  if [[ "$(echo "$clusterNodes" |grep -Ev "$expectedNodes")" =~ [a-z0-9]+ ]];then
    log --debug "
      clusterNodes for node $targetIp dismatched cluster：
      $clusterNodes
    "
    clusterMatched="false"
  fi
  echo "$clusterMatched"
}

checkGroupMatched() {
  local targetIps="${1:-$MY_IP}"
  local targetIp; for targetIp in $targetIps; do
    [[ "$(getGroupMatched "$targetIp")" == "true" ]] || {
      log "Found mismatched group for node '$targetIp'."

      return $GROUP_MATCHED_ERR
    }
  done
}

checkClusterMatched() {
  local targetIps="${1:-$MY_IP}"
  local targetIp; for targetIp in $targetIps; do
    [[ "$(getClusterMatched "$targetIp")" == "true" ]] || {
      log "Found mismatched cluster for node '$targetIp'."
      return $CLUSTER_MATCHED_ERR
    }
  done
}

checkGroupMatchedCommand(){
  local needToCheckGroupMatchedCommand needToCheckGroupMatchedCommands
  needToCheckGroupMatchedCommand="${1?command is required}"
  needToCheckGroupMatchedCommands="preScaleOut preScaleIn"
  if [[ "$needToCheckGroupMatchedCommands" == *"$needToCheckGroupMatchedCommand"* ]]; then
    log "needToCheckGroupMatchedCommand: $needToCheckGroupMatchedCommand"
    local stableNodesIps; stableNodesIps="$(getStableNodesIps)"
    checkGroupMatched "$stableNodesIps"
    checkClusterMatched "$stableNodesIps"
  fi
}

getNodesOrder() {
  local nodesStatus nodesList failInfo result
  nodesStatus="$(runRedisCmd CLUSTER NODES | awk -F "[ :]+" '{sub(/^myself,/,"",$4);{print $2"/"$4}}')"
  failInfo="$(echo "$nodesStatus"| xargs -n1 | awk -F "/" '$2 !~ /^(master|slave)$/{print}')"
  if [ "$failInfo" != "" ];then
    log "node fail: $(echo "$failInfo" | xargs -n1 | paste -sd ";" )"
    return $CLUSTER_NODE_ERR
  fi
  nodesList="$(join -1 5 -2 1 -t/ -o 1.1,2.2,1.4 <(echo "$REDIS_NODES" | xargs -n1 | sort -t "/" -k 5 ) <(echo "$nodesStatus" | xargs -n1 | sort))"
  result="$(echo "$nodesList" | xargs -n1 | sort -t"/" -k 2r,2 -k 1rn | cut -f3 -d/ | paste -sd ",")"
  log "$result"
  echo $result
}

getUserList() {
  log "log getUserList"
  [[ "$ENABLE_ACL" == "no" ]] && return $ACL_SWITCH_ERR
  local ACL_CMD=$(getRuntimeNameOfCmd ACL)
  awk '{ a=""
      if ($2!="default") {
        for (i=1;i<=NF;i++){
          if ($i ~ /^[+\-~&]|^(allchannels|resetchannels|allcommands|nocommands)/) {
            a=a$i" "
          }
        }
        print $2"\t"$3"\t"a
      }
    }' <(runRedisCmd $ACL_CMD list) \
  | jq -Rc 'split("\t") | [ . ]' | jq -s add | jq -c '{"labels":["user","switch","rules"],"data":.}'
}

aclList(){
  local ACL_CMD="$(getRuntimeNameOfCmd ACL)"
  runRedisCmd $ACL_CMD list
}

aclManage() {
  local command="$1"; shift 1
  local args=$@
  log "$command start"
  [[ "$ENABLE_ACL" == "no" ]] && {
    log "Add User Error Not ENABLE_ACL."
    return $ACL_SWITCH_ERR
  }
  local user="$(echo $args |jq -r .username)"
  [[ "$user" == "default" ]] && return $ACL_MANAGE_ERR
  local ACL_CMD="$(getRuntimeNameOfCmd ACL)"
  local acl_users="$(runRedisCmd $ACL_CMD USERS|awk 'BEGIN{ORS=" "}$0!="default"')"
  if [[ "$command" == "addUser" ]];then
    local passwd="$(echo -n "$(echo $args |jq -r .passwd)" | openssl sha256 | awk '{print "#"$NF}')"
    local switch="$(echo $args |jq -r .switch)" rules="$(echo $args |jq -j .rules|sed 's/\r//g'| xargs)"
    [[ " $acl_users " =~ " $user " ]] && return $ACL_MANAGE_ERR
    runRedisCmd $ACL_CMD SETUSER $user $switch $passwd $rules || {
      log "Add User Error ($?)"
      return $ACL_MANAGE_ERR
    }
  elif [[ "$command" == "setUserRules" ]];then
    local sre_info=$(runRedisCmd $ACL_CMD LIST | awk -v user="$user" '$2==user{txt=$3; for (i=4;i<=NF;i++){if ($i~/^#/){txt=txt" "$i }};print txt}')
    local rules="$(echo $args |jq -j .rules|sed 's/\r//g'| xargs)"
    runRedisCmd $ACL_CMD DELUSER $user || {
      log "DELUSER User Error ($?)"
      return $ACL_MANAGE_ERR
    }
    runRedisCmd $ACL_CMD SETUSER $user $sre_info $rules || {
      log "Set User Rules Error ($?)"
      return $ACL_MANAGE_ERR
    }
  elif [[ "$command" == "delUser" ]];then
    [[ " $acl_users " =~ " $user " ]] || return $ACL_MANAGE_ERR
    runRedisCmd $ACL_CMD DELUSER $user || {
      log "DELUSER User Error ($?)"
      return $ACL_MANAGE_ERR
    }
  elif [[ "$command" == "setSwitch" ]];then
    [[ " $acl_users " =~ " $user " ]] || return $ACL_MANAGE_ERR
    local switch="$(echo $args |jq -r .switch)"
    runRedisCmd $ACL_CMD SETUSER $user $switch || {
      log "Setuser switch User Error ($?)"
      return $ACL_MANAGE_ERR
    }
  elif [[ "$command" == "resetPasswd" ]];then
    [[ " $acl_users " =~ " $user " ]] || return $ACL_MANAGE_ERR
    local passwd="$(echo -n "$(echo $args |jq -r .passwd)" | openssl sha256 | awk '{print "#"$NF}')"
    runRedisCmd $ACL_CMD SETUSER $user resetpass || {
      log "$ACL_CMD SETUSER $user resetpass Error ($?)"
      return $ACL_MANAGE_ERR
    }
    runRedisCmd $ACL_CMD SETUSER $user $passwd || {
      log "$ACL_CMD SETUSER $user $passwd  Error ($?)"
      return $ACL_MANAGE_ERR
    }
  fi

  log "acl $command SAVE"
  runRedisCmd $ACL_CMD SAVE
  log "acl $command end"
}

clusterFailover() {
  log "manual failover to promote me to be the master, begin..."
  # timeout 120s
  runRedisCmd --timeout 120 CLUSTER FAILOVER
  log "manual failover to promote me to be the master, done."
}

upgrade() {
  chown syslog:adm /data/appctl/logs/* || :
  initNode
  configure

  # only for upgrade to 7.2.9
  # if from version is 7.2.9 or above, should remove the codes below
  if [ $MY_ROLE = "master" ]; then
    return 0
  fi
  cmdFlushDB=$(getRuntimeNameOfCmd "FLUSHDB")
  cmdFlushDBOld=$(getRuntimeNameOfCmd --node-id "$NODE_ID" "FLUSHDB")
  cmdFlushAll=$(getRuntimeNameOfCmd "FLUSHALL")
  cmdFlushAllOld=$(getRuntimeNameOfCmd --node-id "$NODE_ID" "FLUSHALL")
  
  log "hack for master-replica"
  log "replace FLUSHDB/FLUSHALL hash in *.aof"
  find $REDIS_DIR/appendonlydir -type f -name "*.aof" -exec sed -i "s/$cmdFlushDBOld/$cmdFlushDB/g; s/$cmdFlushAllOld/$cmdFlushAll/g" {} \;
}

isMaster() {
  local res=$(runRedisCmd INFO REPLICATION)
  echo "$res" | grep 'role:master'
}

preBackup(){
  local info info=$(runRedisCmd info all)
  echo "$info" | awk -F "[\r:]+" '/^(loading|rdb_bgsave_in_progress|aof_rewrite_in_progress|master_sync_in_progress):/{count+=$2}END{exit count}'
}

lxcCheck() {
  local res=$(systemd-detect-virt)
  if [ "$res" = "lxc" ]; then return 0; fi
  return 1
}

# only exec on node which role is master
backup2() {
  if lxcCheck; then
    log "unsupported virt type: lxc, exit!"
    return $LXC_UNSUPPORT_ERR
  fi
  log "Start backup"
  # check if need failover
  while ! isMaster; do
    # "failover"
    clusterFailover
    # wait 10s
    sleep 10
  done
  retry 600 3 0 preBackup

  local lastsave="LASTSAVE" bgsave="BGSAVE"
  local lastsaveCmd bgsaveCmd; lastsaveCmd="$(getRuntimeNameOfCmd $lastsave)" bgsaveCmd="$(getRuntimeNameOfCmd $bgsave)"
  local lastTime; lastTime="$(runRedisCmd $lastsaveCmd)"
  runRedisCmd $bgsaveCmd
  retry 600 3 $EC_BACKUP_ERR checkBgsaveDone $lastTime
  log "backup successfully"
}

APPCTL_ENV_FILE=/opt/app/bin/envs/appctl.env
# appctl.env
# REVIVE_ENABLED=false
disableHealthCheck() {
  sed -i '/^REVIVE_ENABLED/d' $APPCTL_ENV_FILE
  echo "REVIVE_ENABLED=false" >> $APPCTL_ENV_FILE
}

enableHealthCheck() {
  sed -i '/^REVIVE_ENABLED/d' $APPCTL_ENV_FILE
}

restoreReplica() {
  log "restore replica"
  # clear node-6379.conf
  >$NODE_CONF_FILE || :
  # remove dump.rdb
  rm -f $REDIS_DIR/dump.rdb
  # remove aof files
  rm -rf $REDIS_DIR/appendonlydir/*
  # recreate redis.conf: rename-command issue
  configureForRedis
  # start myself
  start
  log "restore replica, done"
}

getFirstMasterIp() {
  local nodeRole
  local node; for node in $REDIS_NODES; do
    nodeRole=$(echo "$node" | cut -d'/' -f3)
    if [ "$nodeRole" = "master" ]; then
      echo "${node##*/}"
      break
    fi
  done
}

clusterMeet() {
  log "cluster meet $1, begin"
  if ! runRedisCmd CLUSTER MEET $1 $REDIS_PORT $CLUSTER_PORT; then
    log "cluster meet $1, failed."
    return 1
  fi
  log "cluster meet $1, done"
  return 0
}

batchClusterMeetMaster() {
  local nodeRole nodeIp
  local node; for node in $REDIS_NODES; do
    nodeRole=$(echo "$node" | cut -d'/' -f3)
    nodeIp="${node##*/}"
    if [ ! "$nodeRole" = "master" ]; then
      log "skip role: $nodeRole, $nodeIp"
      continue
    fi
    if [ "$nodeIp" = "$MY_IP" ]; then continue; fi
    log "use role: $nodeRole, $nodeIp"
    retry 600 6 0 clusterMeet $nodeIp
  done
}

getMasterIdByNodeIp() {
  local tmplConf=/opt/app/conf/redis-cluster/nodes-6379.conf
  grep $1 $tmplConf | awk '{print $4}'
}

clusterAddReplia() {
  log "cluster add replica $1, begin"
  if ! runRedisCmd --cluster add-node $1:$REDIS_PORT $MY_IP:$REDIS_PORT --cluster-slave --cluster-master-id $2; then
    log "cluster add replica $1, failed."
    return 1
  fi
  log "cluster add replica $1, done"
  return 0
}

batchClusterAddReplica() {
  local nodeRole nodeIp masterId
  local node; for node in $REDIS_NODES; do
    nodeRole=$(echo "$node" | cut -d'/' -f3)
    if [ "$nodeRole" = "master" ]; then
      continue
    fi
    nodeIp="${node##*/}"
    masterId="$(getMasterIdByNodeIp $nodeIp)"
    retry 600 6 0 clusterAddReplia $nodeIp $masterId
  done
}

getRestoreMasterIps() {
  local nodeRole nodeIp ips=""
  local node; for node in $REDIS_NODES; do
    nodeRole=$(echo "$node" | cut -d'/' -f3)
    if [ ! "$nodeRole" = "master" ]; then
      continue
    fi
    ips="$ips ${node##*/}"
  done
  echo $ips
}

restoreMaster() {
  log "restore master"
  local tmplConf=/opt/app/conf/redis-cluster/nodes-6379.conf
  local runid=$(grep "myself" "$tmplConf" | awk '{print $1}')
  # remove aof files
  rm -rf $REDIS_DIR/appendonlydir/*
  # only reserve myself
  sed -i '/myself/!d' $NODE_CONF_FILE
  # use new runid
  sed -i "s/^[^ ]*/$runid/" $NODE_CONF_FILE
  # use new ip
  sed -i "s/\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\):/$MY_IP:/" $NODE_CONF_FILE
  # recreate redis.conf: rename-command issue
  configureForRedis
  # get appendonly
  local appendonly=$(grep '^appendonly' $RUNTIME_CONFIG_FILE | cut -d' ' -f2)
  if [ "$appendonly" = "yes" ]; then
    log "routine: when appendonly=yes"
    # temporary set appendonly no
    sed -i 's/^appendonly .*$/appendonly no/' $RUNTIME_CONFIG_FILE
    # first start redis
    log "start redis with 'appendonly no'"
    start
    sleep 10s
    # bgrewriteaof
    retry 600 5 0 runRedisCmd $(getRuntimeNameOfCmd "BGREWRITEAOF")
    # check if bgrewriteaof done
    retry 600 5 0 checkBgrewriteofDone
    # set appendonly back to yes
    sed -i 's/^appendonly .*$/appendonly yes/' $RUNTIME_CONFIG_FILE
    # second restart redis
    systemctl restart redis-server
  else
    log "routine: when appendonly=no"
    start
  fi
  
  # wait for all nodes started
  sleep 10s
  
  # retry to meet other master
  local firstIp=$(getFirstMasterIp)
  if [ ! "$firstIp" = "$MY_IP" ]; then
    log "not the first master, job is done"
    return 0
  fi
  log "try to meet other masters"
  batchClusterMeetMaster
  # wait for all master nodes ok
  waitUntilAllNodesIsOk "$(getRestoreMasterIps)"
  log "try to add replicas"
  batchClusterAddReplica
  log "restore master, done"
}

restore() {
  log "start restore"
  if [ "$MY_ROLE" = "master" ]; then
    restoreMaster
  else
    restoreReplica
  fi
  log "restore successfully"
}