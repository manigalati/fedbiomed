import unittest
import asyncio 

from unittest.mock import patch, MagicMock, AsyncMock

from fedbiomed.transport.node_agent import NodeAgent, NodeAgentAsync, NodeActiveStatus, AgentStore
from fedbiomed.common.exceptions import FedbiomedCommunicationError
from fedbiomed.common.message import SearchRequest



message = MagicMock(spec=SearchRequest)


class TestNodeAgent(unittest.IsolatedAsyncioTestCase):

    def setUp(self):

        self.loop = asyncio.get_event_loop_policy().get_event_loop()
        self.node_agent = NodeAgent(
            id='node-1',
            loop=self.loop
        )

    def tearDown(self) -> None:
        return super().tearDown()


    def test_node_agent_01_id(self):

        id = self.node_agent.id
        self.assertEqual(id, 'node-1')


    async def test_node_agent_02_status(self):

        status = await self.node_agent.status_async()
        self.assertEqual(status, NodeActiveStatus.ACTIVE)

    async def test_node_agent_03_set_active(self):

        status_task = MagicMock()

        self.node_agent._status_task = status_task
        self.node_agent._status = NodeActiveStatus.DISCONNECTED
        await self.node_agent.set_active()
        status_task.cancel.assert_called_once()

    async def test_node_agent_04_send(self):

        self.node_agent._status = NodeActiveStatus.DISCONNECTED
        r = await self.node_agent.send_async(message=message)
        self.assertIsNone(r) 

        self.node_agent._status = NodeActiveStatus.WAITING
        r = await self.node_agent.send_async(message=message)
        item = await self.node_agent._queue.get()
        self.assertEqual(item, message) 

        self.node_agent._status = NodeActiveStatus.ACTIVE
        r = await self.node_agent.send_async(message=message)
        item = await self.node_agent._queue.get()
        self.assertEqual(item, message) 

        with patch('fedbiomed.transport.node_agent.asyncio.Queue.put') as put:
            put.side_effect = Exception
            with self.assertRaises(Exception):
                await self.node_agent.send_async(message=message)


    async def test_node_agent_05_set_context(self):

        context = MagicMock()
        self.node_agent.set_context(context)
        context.add_done_callback.assert_called_once_with(self.node_agent._on_get_task_request_done)

    async def test_node_agent_06_get_task(self):

        await self.node_agent._queue.put(message)
        r = await self.node_agent.get_task()
        self.assertEqual(r, message)

    async def test_node_agent_07_task_done(self):

       with patch('fedbiomed.transport.node_agent.asyncio.Queue.task_done') as task_done:
            self.node_agent.task_done()
            task_done.assert_called_once()


    async def test_node_agent_08_private_on_get_task_request_done(self):

        context = MagicMock()

        with patch('fedbiomed.transport.node_agent.NodeAgent._change_node_status_after_task', AsyncMock()) as cns:
            self.node_agent._on_get_task_request_done(context)
            self.assertTrue(self.node_agent._is_waiting.is_set())
            cns.assert_called_once()

    async def test_node_agent_09_private_change_node_status_after_task(self):
        """ Tests two methods 

        - _change_node_status_after_task
        - _change_node_status_disconnected

        """
        with patch('fedbiomed.transport.node_agent.asyncio.sleep') as sleep:
            self.node_agent._is_waiting.set()
            await self.node_agent._change_node_status_after_task()
            self.node_agent._status = NodeActiveStatus.WAITING
            await self.node_agent._status_task
            self.assertEqual(self.node_agent._status, NodeActiveStatus.DISCONNECTED)




class TestAgentStore(unittest.IsolatedAsyncioTestCase):

    def setUp(self):

        self.loop = asyncio.get_event_loop_policy().get_event_loop()
        self.agent_store = AgentStore(
            loop=self.loop
        )

    async def test_agent_store_01_retrieve(self):
        mock = MagicMock()
        node_agent = await self.agent_store.retrieve(node_id='node-id', context=mock)
        self.assertTrue('node-id' in self.agent_store._node_agents)
        self.assertIsInstance(node_agent, NodeAgent)


    async def test_agent_store_02_get_all(self):
        
        mock = MagicMock()
        # Register node agents
        await self.agent_store.retrieve(node_id='node-id-1', context=mock)
        await self.agent_store.retrieve(node_id='node-id-2', context=mock)

        all_ = await self.agent_store.get_all()

        # Try to update
        all_['node-id-2'] = True
        self.assertFalse(self.agent_store._node_agents['node-id-2'] == True)

    async def test_agent_store_03_get(self):
        
        mock = MagicMock()
        # Register node agents
        await self.agent_store.retrieve(node_id='node-id-1', context=mock)
        await self.agent_store.retrieve(node_id='node-id-2', context=mock)

        result = await self.agent_store.get('node-id-1')
        self.assertEqual(result.id, 'node-id-1')

if __name__ == '__main__':
    unittest.main()