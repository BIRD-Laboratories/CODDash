import asyncio
import json
import logging
import sys
import os
from typing import Dict, List

# Check for real libraries
try:
    import proxmoxer
    HAS_PROXMOXER = True
    print("✓ proxmoxer library available")
except ImportError as e:
    print(f"✗ proxmoxer not available: {e}")
    HAS_PROXMOXER = False

# We'll use direct HTTP API for Guacamole since there's no reliable PyPI package
HAS_GUACAMOLE = True  # We'll implement direct API calls
print("✓ Using direct HTTP API for Guacamole")

class RealProxmoxManager:
    """Real Proxmox manager using proxmoxer library"""
    
    def __init__(self, config, logger):
        self.config = config
        self.logger = logger
        self.proxmox = None
        self.node = config['proxmox']['node']
        
    async def initialize(self):
        try:
            self.logger.info(f"Connecting to Proxmox at {self.config['proxmox']['host']}")
            
            self.proxmox = proxmoxer.ProxmoxAPI(
                self.config['proxmox']['host'],
                user=self.config['proxmox']['username'],
                password=self.config['proxmox']['password'],
                verify_ssl=self.config['proxmox'].get('verify_ssl', False)
            )
            
            # Test connection by listing nodes
            nodes = self.proxmox.nodes.get()
            node_names = [node['node'] for node in nodes]
            self.logger.info(f"Connected to Proxmox. Available nodes: {node_names}")
            
            if self.node not in node_names:
                self.logger.error(f"Configured node '{self.node}' not found in available nodes: {node_names}")
                return False
                
            return True
            
        except Exception as e:
            self.logger.error(f"Failed to initialize Proxmox connection: {e}")
            return False

    async def clone_vm(self, template_id, new_id, name, ip_config):
        try:
            self.logger.info(f"Cloning VM from template {template_id} to {new_id} ({name})")
            
            # Clone VM
            task = self.proxmox.nodes(self.node).qemu(template_id).clone.post(
                newid=new_id,
                name=name,
                full=1
            )
            
            self.logger.info(f"Clone task started: {task}")
            
            # Wait for task to complete
            if await self._wait_for_task(task):
                # Configure network if IP provided
                if ip_config and ip_config.get('ip'):
                    await self._configure_vm_network(new_id, ip_config)
                return True
            return False
            
        except Exception as e:
            self.logger.error(f"Failed to clone VM: {e}")
            return False

    async def _wait_for_task(self, task, timeout=300):
        """Wait for Proxmox task to complete"""
        import time
        start_time = time.time()
        
        while time.time() - start_time < timeout:
            try:
                # Extract task ID from response
                if hasattr(task, 'get'):
                    task_id = task.get('data')
                else:
                    task_id = task
                    
                task_status = self.proxmox.nodes(self.node).tasks(task_id).status.get()
                if task_status['status'] == 'stopped':
                    return task_status.get('exitstatus') == 'OK'
                await asyncio.sleep(2)
            except Exception as e:
                self.logger.error(f"Error checking task status: {e}")
                return False
        return False

    async def _configure_vm_network(self, vm_id, ip_config):
        """Configure VM network settings"""
        try:
            # This would need to be customized based on your VM configuration
            # Example: set static IP via cloud-init or VM config
            self.logger.info(f"Configuring network for VM {vm_id} with IP {ip_config['ip']}")
            
            # Example: Set VM description with IP
            self.proxmox.nodes(self.node).qemu(vm_id).config.put(
                description=f"Dynamic VM - IP: {ip_config['ip']}"
            )
            
            return True
        except Exception as e:
            self.logger.error(f"Failed to configure VM network: {e}")
            return False

    async def start_vm(self, vm_id):
        try:
            result = self.proxmox.nodes(self.node).qemu(vm_id).status.start.post()
            self.logger.info(f"Started VM {vm_id}: {result}")
            return True
        except Exception as e:
            self.logger.error(f"Failed to start VM {vm_id}: {e}")
            return False

    async def stop_vm(self, vm_id):
        try:
            result = self.proxmox.nodes(self.node).qemu(vm_id).status.stop.post()
            self.logger.info(f"Stopped VM {vm_id}: {result}")
            return True
        except Exception as e:
            self.logger.error(f"Failed to stop VM {vm_id}: {e}")
            return False

    async def get_vm_status(self, vm_id):
        try:
            status = self.proxmox.nodes(self.node).qemu(vm_id).status.current.get()
            return {
                'status': status['status'],
                'vmid': vm_id,
                'name': status.get('name', ''),
                'agent': status.get('agent', False)
            }
        except Exception as e:
            self.logger.error(f"Failed to get VM status for {vm_id}: {e}")
            return {'status': 'unknown'}

    async def list_vms(self):
        try:
            vms = self.proxmox.nodes(self.node).qemu.get()
            return [{
                'vmid': vm['vmid'],
                'status': vm['status'],
                'name': vm.get('name', '')
            } for vm in vms]
        except Exception as e:
            self.logger.error(f"Failed to list VMs: {e}")
            return []

    async def close(self):
        self.logger.info("Proxmox Manager closed")

class RealGuacamoleManager:
    """Real Guacamole manager using direct HTTP API"""
    
    def __init__(self, config, logger):
        self.config = config
        self.logger = logger
        self.base_url = config['guacamole']['url'].rstrip('/')
        self.username = config['guacamole']['username']
        self.password = config['guacamole']['password']
        self.token = None
        self.data_source = 'postgresql'  # or 'mysql' depending on your setup
        
    async def initialize(self):
        try:
            self.logger.info(f"Connecting to Guacamole at {self.base_url}")
            
            # Get auth token
            self.token = await self._get_auth_token()
            if self.token:
                self.logger.info("Successfully authenticated with Guacamole")
                return True
            return False
            
        except Exception as e:
            self.logger.error(f"Failed to initialize Guacamole connection: {e}")
            return False

    async def _get_auth_token(self):
        """Get authentication token from Guacamole"""
        import aiohttp
        import json
        
        auth_data = {
            'username': self.username,
            'password': self.password
        }
        
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{self.base_url}/api/tokens",
                    data=json.dumps(auth_data),
                    headers={'Content-Type': 'application/json'}
                ) as response:
                    if response.status == 200:
                        data = await response.json()
                        return data.get('authToken')
                    else:
                        error_text = await response.text()
                        self.logger.error(f"Auth failed: {response.status} - {error_text}")
                        return None
        except Exception as e:
            self.logger.error(f"Authentication error: {e}")
            return None

    async def _guacamole_api_call(self, method, endpoint, data=None):
        """Make API call to Guacamole"""
        import aiohttp
        
        if not self.token:
            if not await self.initialize():
                return None
            
        headers = {
            'Content-Type': 'application/json',
            'Guacamole-Token': self.token
        }
        
        try:
            async with aiohttp.ClientSession() as session:
                url = f"{self.base_url}/api/session/data/{self.data_source}/{endpoint}?token={self.token}"
                
                if method.upper() == 'GET':
                    async with session.get(url, headers=headers) as response:
                        return await response.json() if response.status == 200 else None
                elif method.upper() == 'POST':
                    async with session.post(url, headers=headers, json=data) as response:
                        return await response.json() if response.status == 200 else None
                elif method.upper() == 'PUT':
                    async with session.put(url, headers=headers, json=data) as response:
                        return await response.json() if response.status == 200 else None
                elif method.upper() == 'DELETE':
                    async with session.delete(url, headers=headers) as response:
                        return response.status == 204
        except Exception as e:
            self.logger.error(f"API call failed: {e}")
            return None

    async def create_connection(self, vm_config):
        try:
            connection_data = {
                "parentIdentifier": "ROOT",
                "name": vm_config['name'],
                "protocol": "rdp",
                "parameters": {
                    "hostname": vm_config['ip'],
                    "port": "3389",
                    "username": vm_config.get('username', 'administrator'),
                    "password": vm_config.get('password', ''),
                    "security": "any",
                    "ignore-cert": "true",
                    "width": vm_config.get('width', '1024'),
                    "height": vm_config.get('height', '768'),
                    "dpi": vm_config.get('dpi', '96')
                },
                "attributes": {
                    "max-connections": "10",
                    "max-connections-per-user": "10"
                }
            }
            
            result = await self._guacamole_api_call('POST', 'connections', connection_data)
            if result and 'identifier' in result:
                self.logger.info(f"Created Guacamole connection: {result['identifier']}")
                return result['identifier']
            else:
                self.logger.error(f"Failed to create connection: {result}")
                return None
            
        except Exception as e:
            self.logger.error(f"Failed to create Guacamole connection: {e}")
            return None

    async def delete_connection(self, connection_id):
        try:
            success = await self._guacamole_api_call('DELETE', f'connections/{connection_id}')
            if success:
                self.logger.info(f"Deleted Guacamole connection {connection_id}")
            return success
        except Exception as e:
            self.logger.error(f"Failed to delete connection {connection_id}: {e}")
            return False

    async def get_active_connections(self):
        try:
            result = await self._guacamole_api_call('GET', 'activeConnections')
            return result or {}
        except Exception as e:
            self.logger.error(f"Failed to get active connections: {e}")
            return {}

    async def get_connection_usage(self, connection_id):
        try:
            active = await self.get_active_connections()
            count = 0
            for session_id, session_data in active.items():
                if session_data.get('connectionIdentifier') == connection_id:
                    count += 1
            return count
        except Exception as e:
            self.logger.error(f"Failed to get connection usage: {e}")
            return 0

    async def close(self):
        if self.token:
            # Revoke token
            import aiohttp
            try:
                async with aiohttp.ClientSession() as session:
                    async with session.delete(
                        f"{self.base_url}/api/tokens/{self.token}"
                    ) as response:
                        if response.status == 204:
                            self.logger.info("Guacamole token revoked")
            except Exception as e:
                self.logger.error(f"Error revoking token: {e}")
        self.logger.info("Guacamole Manager closed")

class PFSenseManager:
    """PFSense manager using direct API calls"""
    
    def __init__(self, config, logger):
        self.config = config
        self.logger = logger
        self.base_url = config.get('pfsense', {}).get('url', '')
        self.username = config.get('pfsense', {}).get('username', '')
        self.password = config.get('pfsense', {}).get('password', '')
        
    async def initialize(self):
        self.logger.info("PFSense Manager initialized")
        # For now, we'll just log since pfSense API can be complex
        return True
    
    async def create_dhcp_mapping(self, mac_address, ip_address, hostname):
        """Create DHCP static mapping - placeholder implementation"""
        self.logger.info(f"Would create DHCP mapping: {hostname} ({mac_address}) -> {ip_address}")
        # In a real implementation, you would:
        # 1. Use pfSense API (if enabled)
        # 2. Use SSH to modify config files
        # 3. Use web scraping with requests
        return True
    
    async def close(self):
        self.logger.info("PFSense Manager closed")

class DynamicVMService:
    """Main service that uses real managers"""
    
    def __init__(self, config_path):
        self.config_path = config_path
        self.config = self.load_config()
        self.logger = self.setup_logging()
        self.proxmox_manager = None
        self.guacamole_manager = None
        self.pfsense_manager = None
        self.is_running = False
        
    def load_config(self):
        with open(self.config_path, 'r') as f:
            return json.load(f)
    
    def setup_logging(self):
        logging.basicConfig(level=logging.INFO)
        return logging.getLogger('DynamicVMService')
    
    async def start(self):
        self.logger.info("Starting Dynamic VM Service with REAL connections")
        
        # Initialize Proxmox
        if HAS_PROXMOXER:
            self.proxmox_manager = RealProxmoxManager(self.config, self.logger)
            if not await self.proxmox_manager.initialize():
                self.logger.error("Failed to initialize Proxmox manager")
                return False
        else:
            self.logger.error("Proxmoxer not available")
            return False
        
        # Initialize Guacamole
        self.guacamole_manager = RealGuacamoleManager(self.config, self.logger)
        if not await self.guacamole_manager.initialize():
            self.logger.error("Failed to initialize Guacamole manager")
            return False
        
        # Initialize pfSense
        self.pfsense_manager = PFSenseManager(self.config, self.logger)
        await self.pfsense_manager.initialize()
        
        self.is_running = True
        self.logger.info("Dynamic VM Service started successfully")
        return True
    
    async def assign_user_vm(self):
        """Assign a VM to a user"""
        if not self.is_running:
            return None
            
        # This would be your actual assignment logic
        # For now, return a mock response
        return {
            'vm_id': 1001,
            'ip': '192.168.1.100',
            'connection_id': 'conn-1'
        }
    
    async def release_user_vm(self, vm_id):
        """Release a user's VM"""
        if not self.is_running:
            return False
        self.logger.info(f"Released VM {vm_id}")
        return True
    
    async def get_service_status(self):
        """Get service status"""
        if not self.is_running:
            return {'status': 'stopped'}
        
        return {
            'status': 'running',
            'proxmox_connected': self.proxmox_manager is not None,
            'guacamole_connected': self.guacamole_manager is not None,
            'pool': {
                'total_vms': 0,
                'available_vms': 0,
                'total_users': 0,
                'vms': []
            }
        }
    
    async def stop(self):
        self.logger.info("Stopping Dynamic VM Service")
        if self.proxmox_manager:
            await self.proxmox_manager.close()
        if self.guacamole_manager:
            await self.guacamole_manager.close()
        if self.pfsense_manager:
            await self.pfsense_manager.close()
        self.is_running = False

async def test_real_connections():
    """Test real connections to Proxmox and Guacamole"""
    print("\n" + "="*60)
    print("Testing Real Connections")
    print("="*60)
    
    if not os.path.exists("config.json"):
        print("config.json not found!")
        print("Please create config.json with your Proxmox and Guacamole credentials")
        return
    
    with open("config.json", "r") as f:
        config = json.load(f)
    
    # Setup logging
    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger("RealConnectionTest")
    
    # Test Proxmox
    if HAS_PROXMOXER:
        print("\n1. Testing Proxmox connection...")
        proxmox_mgr = RealProxmoxManager(config, logger)
        if await proxmox_mgr.initialize():
            print("   ✓ Proxmox connection successful!")
            
            # List VMs to verify
            vms = await proxmox_mgr.list_vms()
            print(f"   Found {len(vms)} VMs on node {config['proxmox']['node']}")
            for vm in vms[:5]:  # Show first 5 VMs
                print(f"     - VM {vm['vmid']}: {vm['name']} ({vm['status']})")
            if len(vms) > 5:
                print(f"     ... and {len(vms) - 5} more")
                
            await proxmox_mgr.close()
        else:
            print("   ✗ Proxmox connection failed!")
    else:
        print("   ✗ proxmoxer not available")
    
    # Test Guacamole
    print("\n2. Testing Guacamole connection...")
    guac_mgr = RealGuacamoleManager(config, logger)
    if await guac_mgr.initialize():
        print("   ✓ Guacamole connection successful!")
        
        # Test creating a connection
        test_config = {
            'name': 'test-connection',
            'ip': '192.168.1.100',
            'username': 'administrator'
        }
        conn_id = await guac_mgr.create_connection(test_config)
        if conn_id:
            print(f"   ✓ Test connection created: {conn_id}")
            # Clean up
            await guac_mgr.delete_connection(conn_id)
        else:
            print("   ⚠ Test connection creation failed (might be expected)")
        
        await guac_mgr.close()
    else:
        print("   ✗ Guacamole connection failed!")

if __name__ == "__main__":
    asyncio.run(test_real_connections())
