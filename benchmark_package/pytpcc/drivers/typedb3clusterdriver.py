# -*- coding: utf-8 -*-
# TypeDB 3 Cluster Driver for TPC-C Benchmark
#
# Thin wrapper around Typedb3Driver that adds cluster-specific connection
# setup (peer registration). All TPC-C transaction logic and common config
# are inherited unchanged from the base driver.
# -----------------------------------------------------------------------

import os
import logging
import sys

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from drivers.typedb3driver import Typedb3Driver, EDITION


## ==============================================
## Typedb3ClusterDriver
## ==============================================
class Typedb3ClusterDriver(Typedb3Driver):
    DEFAULT_CONFIG = {
        **Typedb3Driver.DEFAULT_CONFIG,
        "edition": ("TypeDB Edition (Core, Cloud, or Cluster)", "Cluster"),
        "register_peers": ("Peer nodes to register (format: node_id:addr,node_id:addr)", ""),
    }

    def __init__(self, ddl, shared_event=None, worker_id="root"):
        super().__init__(ddl, shared_event=shared_event, worker_id=worker_id)
        self.name = "typedb3cluster"
        self.register_peers = None

        # Override logger name
        filename = f'typedb_cluster_pid_{self.worker_id}.log'
        open(filename, 'w').close()
        self.typedb_logger = logging.getLogger('typedb3cluster')
        handler = logging.FileHandler(filename)
        handler.setFormatter(logging.Formatter('%(asctime)s - %(message)s'))
        self.typedb_logger.addHandler(handler)

    def makeDefaultConfig(self):
        return Typedb3ClusterDriver.DEFAULT_CONFIG

    def loadConfig(self, config):
        for key in Typedb3ClusterDriver.DEFAULT_CONFIG.keys():
            assert key in config, "Missing parameter '%s' in %s configuration" % (key, self.name)

        # Extract cluster-specific config before calling base
        self.register_peers = str(config["register_peers"]) if config["register_peers"] else ""

        # Base handles: common config parsing, driver creation, database setup
        super().loadConfig(config)

        # Register peer nodes (cluster-support-feature-branch only)
        if self.edition is EDITION.Cluster and self.register_peers:
            self.typedb_logger.info(f"Registering peer nodes: {self.register_peers}")
            for peer in self.register_peers.split(","):
                peer = peer.strip()
                if peer:
                    parts = peer.split(":")
                    if len(parts) >= 2:
                        node_id = int(parts[0])
                        addr = ":".join(parts[1:])
                        self.typedb_logger.info(f"Registering node {node_id} at {addr}")
                        try:
                            self.driver.register_replica(node_id, addr)
                        except Exception as e:
                            self.typedb_logger.warning(f"Failed to register node {node_id}: {e}")

    def loadVerify(self):
        self.typedb_logger.info("TypeDB3 Cluster:")
        self.typedb_logger.info(self.get_counts())

    def executeVerify(self):
        self.typedb_logger.info("TypeDB3 Cluster:")
        self.typedb_logger.info(self.get_counts())

## CLASS
