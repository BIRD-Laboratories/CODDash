#!/usr/bin/env python3
"""
Dynamic VM Management System for Proxmox and Apache Guacamole
Manages VM pool based on user load with automatic scaling
"""

import asyncio
import aiohttp
import json
import logging
import time
import ipaddress
from typing import Dict, List, Optional, Set
from dataclasses import dataclass, asdict
from enum import Enum
import os
from pathlib import Path

class VMStatus(Enum):
    CREATING = "creating"
    RUNNING = "running"
    STOPPED = "stopped"
    ERROR = "error"

@dataclass
class VMInfo:
    id: int
    name: str
    ip: str
    status: VMStatus
    guacamole_connection_id: Optional[str] = None
    created_at: float = None
    user_count: int = 0
    last_health_check: float = None
    
    def to_dict(self):
        result = asdict(self)
        result['status'] = self.status.value
        return result

class ConfigManager:
    """Manages configuration loading and validation"""
    
    def __init__(self, config_path: str = "config.json"):
        self.config_path = config_path
        self.config = None
    
    def load_config(self) -> Dict:
        """Load configuration from JSON file"""
        try:
            with open(self.config_path, 'r') as f:
                self.config = json.load(f)
            self._validate_config()
            return self.config
        except FileNotFoundError:
            raise Exception(f"Configuration file not found: {self.config_path}")
        except json.JSONDecodeError as e:
            raise Exception(f"Invalid JSON in configuration file: {e}")
    
    def _validate_config(self):
        """Validate configuration structure"""
        required_sections = ['proxmox', 'guacamole', 'vm', 'network']
        for section in required_sections:
            if section not in self.config:
                raise Exception(f"Missing required configuration section: {section}")
        
        # Validate Proxmox config
        proxmox_req = ['host', 'username', 'password', 'node', 'template_vm_id']
        for key in proxmox_req:
            if key not in self.config['proxmox']:
                raise Exception(f"Missing required Proxmox configuration: {key}")
        
        # Validate VM config
        vm_req = ['base_load', 'users_per_vm', 'max_vms']
        for key in vm_req:
            if key not in self.config['vm']:
                raise Exception(f"Missing required VM configuration: {key}")

class ProxmoxManager:
    def __init__(self, config: Dict, logger: logging.Logger):
        self.config = config
        self.logger = logger
        self.base_url = config['proxmox']['host']
        self.auth_ticket = None
        self.csrf_token = None
        self.session = None

    async def initialize(self):
        """Initialize session and authenticate"""
        self.session = aiohttp.ClientSession()
        await self.authenticate()

    async def authenticate(self):
        """Authenticate with Proxmox API"""
        try:
            auth_data = {
                'username': self.config['proxmox']['username'],
                'password': self.config['proxmox']['password']
            }
            
            async with self.session.post(
                f"{self.base_url}/api2/json/access/ticket",
                data=auth_data,
                ssl=self.config['proxmox'].get('verify_ssl', False)
            ) as response:
                if response.status == 200:
                    data = await response.json()
                    self.auth_ticket = data['data']['ticket']
                    self.csrf_token = data['data']['CSRFPreventionToken']
                    self.logger.info("Successfully authenticated with Proxmox")
                else:
                    text = await response.text()
                    raise Exception(f"Authentication failed: {response.status} - {text}")
        except Exception as e:
            self.logger.error(f"Proxmox authentication failed: {e}")
            raise

    async def clone_vm(self, template_vm_id: int, new_vm_id: int, name: str, ip_config: Dict) -> bool:
        """Clone VM from template"""
        try:
            # Clone VM
            clone_data = {
                'newid': new_vm_id,
                'name': name,
                'full': 1,
                'target': self.config['proxmox']['node']
            }
            
            await self._make_request(
                'POST',
                f"/api2/json/nodes/{self.config['proxmox']['node']}/qemu/{template_vm_id}/clone",
                data=clone_data
            )
            
            self.logger.info(f"VM {new_vm_id} cloned successfully")
            
            # Configure network (using cloud-init)
            network_config = {
                'ipconfig0': f"ip={ip_config['ip']}/24,gw={ip_config['gateway']}",
                'nameserver': ip_config['dns'],
                'ciuser': ip_config.get('username', 'user'),
                'cipassword': ip_config.get('password', 'password')
            }
            
            await self._make_request(
                'POST',
                f"/api2/json/nodes/{self.config['proxmox']['node']}/qemu/{new_vm_id}/config",
                data=network_config
            )
            
            # Start VM
            await self.start_vm(new_vm_id)
            
            return True
            
        except Exception as e:
            self.logger.error(f"Failed to clone VM {new_vm_id}: {e}")
            return False

    async def start_vm(self, vm_id: int) -> bool:
        """Start VM"""
        try:
            await self._make_request(
                'POST',
                f"/api2/json/nodes/{self.config['proxmox']['node']}/qemu/{vm_id}/status/start"
            )
            self.logger.info(f"VM {vm_id} started")
            return True
        except Exception as e:
            self.logger.error(f"Failed to start VM {vm_id}: {e}")
            return False

    async def stop_vm(self, vm_id: int) -> bool:
        """Stop VM"""
        try:
            await self._make_request(
                'POST',
                f"/api2/json/nodes/{self.config['proxmox']['node']}/qemu/{vm_id}/status/stop"
            )
            self.logger.info(f"VM {vm_id} stopped")
            return True
        except Exception as e:
            self.logger.error(f"Failed to stop VM {vm_id}: {e}")
            return False

    async def get_vm_status(self, vm_id: int) -> Dict:
        """Get VM status"""
        try:
            response = await self._make_request(
                'GET',
                f"/api2/json/nodes/{self.config['proxmox']['node']}/qemu/{vm_id}/status/current"
            )
            return response['data']
        except Exception as e:
            self.logger.error(f"Failed to get status for VM {vm_id}: {e}")
            return {}

    async def list_vms(self) -> List[Dict]:
        """List all VMs"""
        try:
            response = await self._make_request(
                'GET',
                f"/api2/json/nodes/{self.config['proxmox']['node']}/qemu"
            )
            return response['data']
        except Exception as e:
            self.logger.error(f"Failed to list VMs: {e}")
            return []

    async def _make_request(self, method: str, endpoint: str, data: Dict = None) -> Dict:
        """Make authenticated request to Proxmox API"""
        if not self.auth_ticket:
            await self.authenticate()

        headers = {
            'Cookie': f'PVEAuthCookie={self.auth_ticket}',
            'CSRFPreventionToken': self.csrf_token
        }
        
        if data:
            headers['Content-Type'] = 'application/json'
        
        async with self.session.request(
            method,
            f"{self.base_url}{endpoint}",
            headers=headers,
            json=data,
            ssl=self.config['proxmox'].get('verify_ssl', False)
        ) as response:
            if response.status == 200:
                return await response.json()
            else:
                text = await response.text()
                raise Exception(f"API request failed: {response.status} - {text}")

    async def close(self):
        """Close session"""
        if self.session:
            await self.session.close()

class GuacamoleManager:
    def __init__(self, config: Dict, logger: logging.Logger):
        self.config = config
        self.logger = logger
        self.base_url = config['guacamole']['host']
        self.auth_token = None
        self.session = None

    async def initialize(self):
        """Initialize session and authenticate"""
        self.session = aiohttp.ClientSession()
        await self.authenticate()

    async def authenticate(self):
        """Authenticate with Guacamole API"""
        try:
            auth_data = {
                'username': self.config['guacamole']['username'],
                'password': self.config['guacamole']['password']
            }
            
            async with self.session.post(
                f"{self.base_url}/api/tokens",
                data=auth_data
            ) as response:
                if response.status == 200:
                    data = await response.json()
                    self.auth_token = data['authToken']
                    self.logger.info("Successfully authenticated with Guacamole")
                else:
                    text = await response.text()
                    raise Exception(f"Authentication failed: {response.status} - {text}")
        except Exception as e:
            self.logger.error(f"Guacamole authentication failed: {e}")
            raise

    async def create_connection(self, vm_config: Dict) -> Optional[str]:
        """Create Guacamole connection for VM"""
        try:
            connection_config = {
                'parentIdentifier': 'ROOT',
                'name': vm_config['name'],
                'protocol': 'rdp',
                'parameters': {
                    'hostname': vm_config['ip'],
                    'port': '3389',
                    'username': vm_config.get('username', 'administrator'),
                    'password': vm_config.get('password', 'password'),
                    'ignore-cert': 'true',
                    'security': 'any'
                },
                'attributes': {
                    'max-connections': self.config['vm']['users_per_vm'],
                    'max-connections-per-user': self.config['vm']['users_per_vm']
                }
            }
            
            headers = {
                'Guacamole-Token': self.auth_token,
                'Content-Type': 'application/json'
            }
            
            data_source = self.config['guacamole'].get('data_source', 'mysql')
            
            async with self.session.post(
                f"{self.base_url}/api/session/data/{data_source}/connections",
                headers=headers,
                json=connection_config
            ) as response:
                if response.status == 200:
                    data = await response.json()
                    self.logger.info(f"Guacamole connection created for VM {vm_config['name']}")
                    return data['identifier']
                else:
                    text = await response.text()
                    raise Exception(f"Connection creation failed: {response.status} - {text}")
                    
        except Exception as e:
            self.logger.error(f"Failed to create Guacamole connection: {e}")
            return None

    async def delete_connection(self, connection_id: str) -> bool:
        """Delete Guacamole connection"""
        try:
            headers = {'Guacamole-Token': self.auth_token}
            data_source = self.config['guacamole'].get('data_source', 'mysql')
            
            async with self.session.delete(
                f"{self.base_url}/api/session/data/{data_source}/connections/{connection_id}",
                headers=headers
            ) as response:
                if response.status == 204:
                    self.logger.info(f"Guacamole connection {connection_id} deleted")
                    return True
                else:
                    return False
                    
        except Exception as e:
            self.logger.error(f"Failed to delete Guacamole connection: {e}")
            return False

    async def get_active_connections(self) -> Dict:
        """Get active connections"""
        try:
            headers = {'Guacamole-Token': self.auth_token}
            data_source = self.config['guacamole'].get('data_source', 'mysql')
            
            async with self.session.get(
                f"{self.base_url}/api/session/data/{data_source}/activeConnections",
                headers=headers
            ) as response:
                if response.status == 200:
                    return await response.json()
                else:
                    return {}
        except Exception as e:
            self.logger.error(f"Failed to get active connections: {e}")
            return {}

    async def get_connection_usage(self, connection_id: str) -> int:
        """Get number of active users for connection"""
        try:
            active_connections = await self.get_active_connections()
            count = 0
            for conn in active_connections.values():
                if conn.get('connectionIdentifier') == connection_id:
                    count += 1
            return count
        except Exception as e:
            self.logger.error(f"Failed to get connection usage: {e}")
            return 0

    async def close(self):
        """Close session"""
        if self.session:
            await self.session.close()

class VMPoolManager:
    def __init__(self, config: Dict, logger: logging.Logger):
        self.config = config
        self.logger = logger
        self.proxmox_manager = ProxmoxManager(config, logger)
        self.guacamole_manager = GuacamoleManager(config, logger)
        
        self.vm_pool: Dict[int, VMInfo] = {}
        self.available_vms: Set[int] = set()
        self.next_vm_id = 100
        self.ip_pool = self._initialize_ip_pool()
        
        self.monitoring_task = None
        self.is_running = False

    def _initialize_ip_pool(self) -> List[str]:
        """Initialize IP address pool"""
        network = ipaddress.ip_network(self.config['network']['subnet'])
        base_ip = ipaddress.ip_address(self.config['network']['base_ip'])
        
        ips = []
        current_ip = base_ip
        for _ in range(self.config['vm']['max_vms']):
            if current_ip in network:
                ips.append(str(current_ip))
                current_ip += 1
            else:
                break
                
        return ips

    def get_next_ip(self) -> Optional[str]:
        """Get next available IP address"""
        if self.ip_pool:
            return self.ip_pool.pop(0)
        return None

    def release_ip(self, ip: str):
        """Release IP address back to pool"""
        if ip not in self.ip_pool:
            self.ip_pool.append(ip)

    async def initialize(self):
        """Initialize managers and ensure base load"""
        await self.proxmox_manager.initialize()
        await self.guacamole_manager.initialize()
        await self.ensure_base_load()
        
        # Start monitoring
        self.is_running = True
        self.monitoring_task = asyncio.create_task(self._monitoring_loop())
        
        self.logger.info("VM Pool Manager initialized successfully")

    async def ensure_base_load(self):
        """Ensure base number of VMs are running"""
        try:
            current_vms = await self.proxmox_manager.list_vms()
            running_vms = [vm for vm in current_vms if vm.get('status') == 'running']
            
            self.logger.info(f"Found {len(running_vms)} running VMs, target: {self.config['vm']['base_load']}")

            # Register existing VMs
            for vm in running_vms:
                if vm['vmid'] != self.config['proxmox']['template_vm_id']:
                    await self._register_existing_vm(vm['vmid'])

            # Create missing VMs
            for i in range(len(self.vm_pool), self.config['vm']['base_load']):
                await self.create_vm()
        except Exception as e:
            self.logger.error(f"Failed to ensure base load: {e}")

    async def _register_existing_vm(self, vm_id: int):
        """Register existing VM in the pool"""
        try:
            status = await self.proxmox_manager.get_vm_status(vm_id)
            if status.get('status') == 'running':
                ip = f"192.168.1.{vm_id}"  # Fallback IP
                
                vm_info = VMInfo(
                    id=vm_id,
                    name=f"existing-vm-{vm_id}",
                    ip=ip,
                    status=VMStatus.RUNNING,
                    created_at=time.time(),
                    user_count=0
                )
                
                self.vm_pool[vm_id] = vm_info
                self.available_vms.add(vm_id)
                
                self.logger.info(f"Registered existing VM {vm_id}")
                
        except Exception as e:
            self.logger.error(f"Failed to register existing VM {vm_id}: {e}")

    async def create_vm(self) -> Optional[VMInfo]:
        """Create a new VM"""
        if len(self.vm_pool) >= self.config['vm']['max_vms']:
            self.logger.error("Maximum VM limit reached")
            return None

        vm_id = self.next_vm_id
        self.next_vm_id += 1
        
        vm_name = f"dynamic-vm-{vm_id}"
        ip = self.get_next_ip()
        
        if not ip:
            self.logger.error("No available IP addresses")
            return None

        ip_config = {
            'ip': ip,
            'gateway': self.config['network']['gateway'],
            'dns': self.config['network']['dns'],
            'username': 'user',
            'password': 'password'
        }

        try:
            # Create VM info with creating status
            vm_info = VMInfo(
                id=vm_id,
                name=vm_name,
                ip=ip,
                status=VMStatus.CREATING,
                created_at=time.time(),
                user_count=0
            )
            
            self.vm_pool[vm_id] = vm_info

            # Clone VM
            success = await self.proxmox_manager.clone_vm(
                self.config['proxmox']['template_vm_id'],
                vm_id,
                vm_name,
                ip_config
            )
            
            if not success:
                raise Exception("VM creation failed")

            # Wait for VM to be ready
            await self._wait_for_vm_ready(vm_id)

            # Create Guacamole connection
            connection_id = await self.guacamole_manager.create_connection({
                'name': vm_name,
                'ip': ip,
                'username': 'user',
                'password': 'password'
            })
            
            if connection_id:
                vm_info.guacamole_connection_id = connection_id
                vm_info.status = VMStatus.RUNNING
            else:
                raise Exception("Guacamole connection creation failed")

            self.available_vms.add(vm_id)
            self.logger.info(f"VM {vm_id} created and ready with IP {ip}")
            return vm_info

        except Exception as e:
            self.logger.error(f"Failed to create VM {vm_id}: {e}")
            vm_info.status = VMStatus.ERROR
            self.release_ip(ip)
            if vm_id in self.vm_pool:
                del self.vm_pool[vm_id]
            return None

    async def _wait_for_vm_ready(self, vm_id: int):
        """Wait for VM to be ready"""
        max_attempts = self.config['monitoring'].get('vm_ready_timeout', 300) // 5
        for attempt in range(max_attempts):
            try:
                status = await self.proxmox_manager.get_vm_status(vm_id)
                if status.get('status') == 'running':
                    self.logger.info(f"VM {vm_id} is ready")
                    return
            except Exception:
                pass
            
            await asyncio.sleep(5)
        
        raise Exception(f"VM {vm_id} failed to become ready within timeout")

    async def assign_vm_to_user(self) -> Optional[VMInfo]:
        """Assign a VM to a user"""
        # Find available VM with lowest user count
        best_vm = None
        min_users = float('inf')
        
        for vm_id in self.available_vms:
            vm_info = self.vm_pool[vm_id]
            if (vm_info.status == VMStatus.RUNNING and 
                vm_info.user_count < min_users and 
                vm_info.user_count < self.config['vm']['users_per_vm']):
                best_vm = vm_info
                min_users = vm_info.user_count
        
        if not best_vm:
            # No available VM, create a new one
            best_vm = await self.create_vm()
            if not best_vm:
                return None
        
        # Update user count
        best_vm.user_count += 1
        self.vm_pool[best_vm.id] = best_vm
        
        # Remove from available if at capacity
        if best_vm.user_count >= self.config['vm']['users_per_vm']:
            self.available_vms.discard(best_vm.id)
        
        self.logger.info(f"Assigned VM {best_vm.id} to user (total users: {best_vm.user_count})")
        return best_vm

    async def release_vm_from_user(self, vm_id: int):
        """Release a VM from user usage"""
        if vm_id in self.vm_pool:
            vm_info = self.vm_pool[vm_id]
            if vm_info.user_count > 0:
                vm_info.user_count -= 1
                
                # Add back to available if not at capacity
                if vm_info.user_count < self.config['vm']['users_per_vm']:
                    self.available_vms.add(vm_id)
                
                self.logger.info(f"Released user from VM {vm_id} (remaining users: {vm_info.user_count})")

    async def get_pool_status(self) -> Dict:
        """Get current pool status"""
        total_vms = len(self.vm_pool)
        available_vms = len(self.available_vms)
        total_users = sum(vm.user_count for vm in self.vm_pool.values())
        
        return {
            'total_vms': total_vms,
            'available_vms': available_vms,
            'total_users': total_users,
            'vms': [vm.to_dict() for vm in self.vm_pool.values()]
        }

    async def _monitoring_loop(self):
        """Monitor and manage VM pool"""
        while self.is_running:
            try:
                if self.config['monitoring'].get('enable_health_checks', True):
                    await self._check_vm_health()
                await self._scale_pool_based_on_load()
                await asyncio.sleep(self.config['vm']['check_interval'])
            except Exception as e:
                self.logger.error(f"Error in monitoring loop: {e}")
                await asyncio.sleep(5)

    async def _check_vm_health(self):
        """Check health of all VMs"""
        for vm_id, vm_info in list(self.vm_pool.items()):
            try:
                status = await self.proxmox_manager.get_vm_status(vm_id)
                if status.get('status') != 'running':
                    vm_info.status = VMStatus.STOPPED
                    self.available_vms.discard(vm_id)
                    self.logger.warning(f"VM {vm_id} is not running")
                else:
                    vm_info.status = VMStatus.RUNNING
                    vm_info.last_health_check = time.time()
            except Exception as e:
                self.logger.error(f"Health check failed for VM {vm_id}: {e}")

    async def _scale_pool_based_on_load(self):
        """Scale VM pool based on current load"""
        total_users = sum(vm.user_count for vm in self.vm_pool.values())
        available_capacity = len(self.available_vms) * self.config['vm']['users_per_vm']
        
        # If we're running low on capacity, create more VMs
        if (available_capacity < 2 and 
            len(self.vm_pool) < self.config['vm']['max_vms']):
            self.logger.info("Low capacity detected, creating additional VM")
            await self.create_vm()

    async def shutdown(self):
        """Shutdown the VM pool manager"""
        self.is_running = False
        if self.monitoring_task:
            self.monitoring_task.cancel()
            try:
                await self.monitoring_task
            except asyncio.CancelledError:
                pass
        
        await self.proxmox_manager.close()
        await self.guacamole_manager.close()

class DynamicVMService:
    def __init__(self, config_path: str = "config.json"):
        self.config_manager = ConfigManager(config_path)
        self.config = self.config_manager.load_config()
        self.setup_logging()
        self.vm_pool_manager = VMPoolManager(self.config, self.logger)
        self.is_running = False

    def setup_logging(self):
        """Setup logging configuration"""
        log_level = getattr(logging, self.config['server'].get('log_level', 'INFO'))
        log_file = self.config['server'].get('log_file', 'vm_service.log')
        
        logging.basicConfig(
            level=log_level,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_file),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger('DynamicVMService')

    async def start(self):
        """Start the service"""
        try:
            await self.vm_pool_manager.initialize()
            self.is_running = True
            self.logger.info("Dynamic VM Service started successfully")
            
            # Keep service running
            while self.is_running:
                await asyncio.sleep(1)
                
        except Exception as e:
            self.logger.error(f"Failed to start service: {e}")
            raise
        finally:
            await self.stop()

    async def stop(self):
        """Stop the service"""
        self.is_running = False
        await self.vm_pool_manager.shutdown()
        self.logger.info("Dynamic VM Service stopped")

    async def assign_user_vm(self) -> Optional[Dict]:
        """Assign a VM to a user"""
        vm_info = await self.vm_pool_manager.assign_vm_to_user()
        if vm_info:
            return {
                'vm_id': vm_info.id,
                'ip': vm_info.ip,
                'guacamole_connection_id': vm_info.guacamole_connection_id,
                'user_count': vm_info.user_count
            }
        return None

    async def release_user_vm(self, vm_id: int):
        """Release a VM from user"""
        await self.vm_pool_manager.release_vm_from_user(vm_id)

    async def get_service_status(self) -> Dict:
        """Get service status"""
        pool_status = await self.vm_pool_manager.get_pool_status()
        return {
            'status': 'running' if self.is_running else 'stopped',
            'pool': pool_status
        }

async def main():
    """Main function"""
    service = DynamicVMService()
    
    try:
        # Start the service
        await service.start()
    except KeyboardInterrupt:
        print("\nShutting down...")
    except Exception as e:
        print(f"Service failed: {e}")
    finally:
        await service.stop()

if __name__ == "__main__":
    asyncio.run(main())
