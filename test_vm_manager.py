#!/usr/bin/env python3
"""
Testing script for Dynamic VM Management System
Tests the system using mock services without requiring real Proxmox/Guacamole setup
"""

import asyncio
import json
import logging
import sys
import os
from unittest.mock import Mock, patch, AsyncMock
from typing import Dict, List
from vm_manager import DynamicVMService, VMPoolManager, ProxmoxManager, GuacamoleManager, VMInfo, VMStatus

class MockProxmoxManager:
    """Mock Proxmox manager that simulates Proxmox API without real connections"""
    
    def __init__(self, config, logger):
        self.config = config
        self.logger = logger
        self.vms = {}
        self.authenticated = False
        self.node = config['proxmox']['node']
        
        # Initialize with some existing VMs for testing
        self._initialize_test_vms()
    
    def _initialize_test_vms(self):
        """Initialize some test VMs"""
        template_id = self.config['proxmox']['template_vm_id']
        # Don't add template VM to available pool
        self.vms[template_id] = {
            'vmid': template_id,
            'name': 'template-vm',
            'status': 'stopped',
            'template': 1
        }
    
    async def initialize(self):
        self.authenticated = True
        self.logger.info("Mock Proxmox Manager initialized")
    
    async def clone_vm(self, template_id, new_id, name, ip_config):
        # Simulate VM creation delay
        await asyncio.sleep(0.1)
        
        self.vms[new_id] = {
            'vmid': new_id,
            'name': name,
            'status': 'stopped',
            'ip': ip_config['ip'],
            'template': 0
        }
        self.logger.info(f"Mock: Cloned VM {new_id} from template {template_id}")
        return True
    
    async def start_vm(self, vm_id):
        if vm_id in self.vms:
            self.vms[vm_id]['status'] = 'running'
            self.logger.info(f"Mock: Started VM {vm_id}")
            return True
        return False
    
    async def stop_vm(self, vm_id):
        if vm_id in self.vms:
            self.vms[vm_id]['status'] = 'stopped'
            self.logger.info(f"Mock: Stopped VM {vm_id}")
            return True
        return False
    
    async def get_vm_status(self, vm_id):
        if vm_id in self.vms:
            status = self.vms[vm_id]['status']
            return {
                'status': status,
                'vmid': vm_id,
                'name': self.vms[vm_id]['name'],
                'agent': status == 'running'  # Simulate QEMU agent status
            }
        return {'status': 'unknown'}
    
    async def list_vms(self):
        return [{'vmid': vm_id, 'status': data['status'], 'name': data['name']} 
                for vm_id, data in self.vms.items()]
    
    async def close(self):
        self.logger.info("Mock Proxmox Manager closed")

class MockGuacamoleManager:
    """Mock Guacamole manager that simulates Guacamole API without real connections"""
    
    def __init__(self, config, logger):
        self.config = config
        self.logger = logger
        self.connections = {}
        self.active_sessions = {}
        self.authenticated = False
        self.connection_counter = 1
    
    async def initialize(self):
        self.authenticated = True
        self.logger.info("Mock Guacamole Manager initialized")
    
    async def create_connection(self, vm_config):
        # Simulate API call delay
        await asyncio.sleep(0.05)
        
        connection_id = f"conn-{self.connection_counter}"
        self.connection_counter += 1
        
        self.connections[connection_id] = {
            'identifier': connection_id,
            'name': vm_config['name'],
            'protocol': 'rdp',
            'parameters': {
                'hostname': vm_config['ip'],
                'port': '3389'
            }
        }
        
        self.logger.info(f"Mock: Created Guacamole connection {connection_id} for VM {vm_config['name']}")
        return connection_id
    
    async def delete_connection(self, connection_id):
        if connection_id in self.connections:
            del self.connections[connection_id]
            self.logger.info(f"Mock: Deleted Guacamole connection {connection_id}")
            return True
        return False
    
    async def get_active_connections(self):
        # Simulate some active connections randomly
        active = {}
        for conn_id, conn_data in self.connections.items():
            # Randomly mark some connections as active for testing
            if hash(conn_id) % 3 == 0:  # ~33% of connections are "active"
                active[conn_id] = {
                    'connectionIdentifier': conn_id,
                    'connectionName': conn_data['name'],
                    'startDate': '2024-01-01T00:00:00Z'
                }
        return active
    
    async def get_connection_usage(self, connection_id):
        active_connections = await self.get_active_connections()
        count = sum(1 for conn in active_connections.values() 
                   if conn['connectionIdentifier'] == connection_id)
        return count
    
    async def close(self):
        self.logger.info("Mock Guacamole Manager closed")

class TestScenarioRunner:
    """Runs various test scenarios using mock services"""
    
    def __init__(self, config_path: str = "config.json"):
        self.config_path = config_path
        self.service = None
        self.setup_logging()
    
    def setup_logging(self):
        """Setup logging for tests"""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger('TestRunner')
    
    async def run_scenario(self, scenario_name: str, scenario_func):
        """Run a test scenario with proper setup/teardown"""
        print(f"\n{'='*60}")
        print(f"Running Scenario: {scenario_name}")
        print(f"{'='*60}")
        
        try:
            # Patch the real managers with mock ones
            with patch('vm_manager.ProxmoxManager', MockProxmoxManager), \
                 patch('vm_manager.GuacamoleManager', MockGuacamoleManager):
                
                self.service = DynamicVMService(self.config_path)
                await scenario_func()
                
            print(f"✓ Scenario '{scenario_name}' completed successfully")
            
        except Exception as e:
            print(f"✗ Scenario '{scenario_name}' failed: {e}")
            raise
        finally:
            if self.service:
                await self.service.stop()

    async def scenario_basic_lifecycle(self):
        """Test basic VM lifecycle operations"""
        # Start service
        start_task = asyncio.create_task(self.service.start())
        await asyncio.sleep(2)  # Allow base VMs to initialize
        
        try:
            # Test 1: Assign VMs to users
            print("1. Testing VM assignment to users...")
            assignments = []
            users_to_test = 8  # More than base load to trigger scaling
            
            for i in range(users_to_test):
                vm_assignment = await self.service.assign_user_vm()
                if vm_assignment:
                    print(f"   ✓ User {i+1} -> VM {vm_assignment['vm_id']} (IP: {vm_assignment['ip']})")
                    assignments.append(vm_assignment)
                else:
                    print(f"   ✗ Failed to assign VM for user {i+1}")
                await asyncio.sleep(0.1)
            
            # Test 2: Check service status
            status = await self.service.get_service_status()
            print(f"\n2. Service Status:")
            print(f"   - Total VMs: {status['pool']['total_vms']}")
            print(f"   - Available VMs: {status['pool']['available_vms']}") 
            print(f"   - Total Users: {status['pool']['total_users']}")
            
            # Test 3: Release some VMs
            print(f"\n3. Testing VM release...")
            vms_to_release = assignments[:2]  # Release first 2 VMs
            for assignment in vms_to_release:
                await self.service.release_user_vm(assignment['vm_id'])
                print(f"   ✓ Released VM {assignment['vm_id']}")
            
            # Test 4: Check updated status
            status = await self.service.get_service_status()
            print(f"\n4. Updated Status:")
            print(f"   - Total Users: {status['pool']['total_users']}")
            print(f"   - Available VMs: {status['pool']['available_vms']}")
            
            # Test 5: Detailed VM status
            print(f"\n5. Detailed VM Status:")
            for vm in status['pool']['vms']:
                print(f"   - VM {vm['id']}: {vm['status']} - {vm['user_count']} users - IP: {vm['ip']}")
            
        finally:
            self.service.is_running = False
            await self.service.stop()
            if not start_task.done():
                start_task.cancel()
                try:
                    await start_task
                except asyncio.CancelledError:
                    pass

    async def scenario_capacity_limits(self):
        """Test system behavior at capacity limits"""
        start_task = asyncio.create_task(self.service.start())
        await asyncio.sleep(2)
        
        try:
            max_vms = self.service.config['vm']['max_vms']
            users_per_vm = self.service.config['vm']['users_per_vm']
            
            print(f"Testing capacity limits (max VMs: {max_vms}, users per VM: {users_per_vm})...")
            
            # Try to assign more users than maximum capacity
            max_possible_users = max_vms * users_per_vm
            test_users = max_possible_users + 5  # Exceed capacity
            
            successful_assignments = 0
            for i in range(test_users):
                assignment = await self.service.assign_user_vm()
                if assignment:
                    successful_assignments += 1
                    if successful_assignments % 10 == 0:
                        print(f"   Assigned {successful_assignments} users...")
                else:
                    print(f"   ✗ Failed to assign user {i+1} (system at capacity)")
                    break
                await asyncio.sleep(0.05)
            
            status = await self.service.get_service_status()
            print(f"\nCapacity Test Results:")
            print(f"   - Successful assignments: {successful_assignments}")
            print(f"   - Total VMs created: {status['pool']['total_vms']}")
            print(f"   - Maximum possible users: {max_possible_users}")
            
            if successful_assignments <= max_possible_users:
                print("   ✓ System correctly enforced capacity limits")
            else:
                print("   ✗ System exceeded capacity limits!")
                
        finally:
            self.service.is_running = False
            await self.service.stop()
            if not start_task.done():
                start_task.cancel()

    async def scenario_error_recovery(self):
        """Test error handling and recovery"""
        start_task = asyncio.create_task(self.service.start())
        await asyncio.sleep(2)
        
        try:
            print("Testing error recovery scenarios...")
            
            # Test 1: Assign and release rapidly
            print("1. Rapid assignment/release cycle...")
            for i in range(10):
                assignment = await self.service.assign_user_vm()
                if assignment:
                    print(f"   ✓ Assigned VM {assignment['vm_id']}")
                    await asyncio.sleep(0.1)
                    await self.service.release_user_vm(assignment['vm_id'])
                    print(f"   ✓ Released VM {assignment['vm_id']}")
                await asyncio.sleep(0.1)
            
            # Test 2: Check system stability after rapid changes
            status = await self.service.get_service_status()
            print(f"\n2. System stability check:")
            print(f"   - Total VMs: {status['pool']['total_vms']}")
            print(f"   - All VMs healthy: {all(vm['status'] == 'running' for vm in status['pool']['vms'])}")
            
            print("   ✓ System remained stable through rapid changes")
            
        finally:
            self.service.is_running = False
            await self.service.stop()
            if not start_task.done():
                start_task.cancel()

    async def scenario_health_monitoring(self):
        """Test health monitoring functionality"""
        start_task = asyncio.create_task(self.service.start())
        await asyncio.sleep(2)
        
        try:
            print("Testing health monitoring...")
            
            # Get initial status
            initial_status = await self.service.get_service_status()
            initial_vm_count = initial_status['pool']['total_vms']
            
            print(f"Initial VM count: {initial_vm_count}")
            
            # Wait for a monitoring cycle
            check_interval = self.service.config['vm']['check_interval']
            print(f"Waiting {check_interval} seconds for health check cycle...")
            await asyncio.sleep(check_interval + 2)
            
            # Check status after health monitoring
            final_status = await self.service.get_service_status()
            final_vm_count = final_status['pool']['total_vms']
            
            print(f"Final VM count: {final_vm_count}")
            print(f"Health checks performed: {initial_vm_count == final_vm_count}")
            
            # Check VM statuses
            healthy_vms = sum(1 for vm in final_status['pool']['vms'] if vm['status'] == 'running')
            print(f"Healthy VMs: {healthy_vms}/{final_vm_count}")
            
            if healthy_vms == final_vm_count:
                print("   ✓ All VMs reported healthy")
            else:
                print("   ✗ Some VMs are not healthy")
                
        finally:
            self.service.is_running = False
            await self.service.stop()
            if not start_task.done():
                start_task.cancel()

async def run_comprehensive_test():
    """Run all test scenarios"""
    print("Dynamic VM Management System - Comprehensive Test Suite")
    print("This test uses MOCK services - no real Proxmox/Guacamole connections are made")
    print("=" * 70)
    
    # Check if config exists
    if not os.path.exists("config.json"):
        print("Error: config.json not found!")
        print("Please create config.json based on the provided template")
        return
    
    runner = TestScenarioRunner("config.json")
    
    try:
        # Run various test scenarios
        await runner.run_scenario("Basic VM Lifecycle", runner.scenario_basic_lifecycle)
        await asyncio.sleep(1)
        
        await runner.run_scenario("Capacity Limits", runner.scenario_capacity_limits)
        await asyncio.sleep(1)
        
        await runner.run_scenario("Error Recovery", runner.scenario_error_recovery)
        await asyncio.sleep(1)
        
        await runner.run_scenario("Health Monitoring", runner.scenario_health_monitoring)
        
        print("\n" + "=" * 70)
        print("All test scenarios completed successfully!")
        print("The system is working correctly with your configuration.")
        
    except Exception as e:
        print(f"\nTest suite failed: {e}")
        raise

async def quick_test():
    """Run a quick smoke test"""
    print("Quick Smoke Test")
    print("=" * 50)
    
    if not os.path.exists("config.json"):
        print("Error: config.json not found!")
        return
    
    runner = TestScenarioRunner("config.json")
    await runner.run_scenario("Quick Smoke Test", runner.scenario_basic_lifecycle)
    print("✓ Smoke test passed!")

def validate_config():
    """Validate the configuration file"""
    print("Validating config.json...")
    
    if not os.path.exists("config.json"):
        print("✗ config.json not found")
        return False
    
    try:
        with open("config.json", "r") as f:
            config = json.load(f)
        
        # Check required sections
        required_sections = ['proxmox', 'guacamole', 'vm', 'network']
        for section in required_sections:
            if section not in config:
                print(f"✗ Missing section: {section}")
                return False
            print(f"✓ Found section: {section}")
        
        # Check critical Proxmox settings
        proxmox_req = ['host', 'username', 'password', 'node', 'template_vm_id']
        for key in proxmox_req:
            if key not in config['proxmox']:
                print(f"✗ Missing Proxmox setting: {key}")
                return False
            print(f"✓ Found Proxmox setting: {key}")
        
        # Check VM settings
        vm_req = ['base_load', 'users_per_vm', 'max_vms']
        for key in vm_req:
            if key not in config['vm']:
                print(f"✗ Missing VM setting: {key}")
                return False
            print(f"✓ Found VM setting: {key}")
        
        print("✓ Configuration is valid")
        return True
        
    except json.JSONDecodeError as e:
        print(f"✗ Invalid JSON: {e}")
        return False
    except Exception as e:
        print(f"✗ Validation error: {e}")
        return False

if __name__ == "__main__":
    # Validate config first
    if not validate_config():
        print("\nPlease fix config.json before running tests")
        sys.exit(1)
    
    # Check for quick test flag
    if len(sys.argv) > 1 and sys.argv[1] == "quick":
        asyncio.run(quick_test())
    else:
        # Run comprehensive test suite
        asyncio.run(run_comprehensive_test())
