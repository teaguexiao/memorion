"""Real image routes and response schemas with storage and inference test doubles."""

import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault('OPENROUTER_API_KEY', 'test')

from fastapi import FastAPI
from fastapi.testclient import TestClient
from langchain_core.messages import AIMessage
from routers import developer_images as route
from utils.llm import image_description


class ImageEndpointTests(unittest.TestCase):
    def setUp(self):
        app = FastAPI()
        app.include_router(route.router)
        app.dependency_overrides[route.get_developer_id_from_api_key] = lambda: 'test-developer'
        self.client = TestClient(app)

    def tearDown(self):
        self.client.close()

    @staticmethod
    def record(**values):
        return dict(values, id='test-image', created_at=datetime.now(timezone.utc),
                    updated_at=datetime.now(timezone.utc))

    def test_base64_and_multipart_uploads_store_the_new_helpers_json(self):
        for raw, mime in ((b'\x89PNG\r\n\x1a\nfixture', 'image/png'), (b'\xff\xd8\xfffixture', 'image/jpeg')):
            for mode in ('base64', 'multipart'):
                llm = mock.Mock()
                llm.ainvoke = mock.AsyncMock(return_value=AIMessage(content='{"text":["TEST 37"],"summary":"card"}'))
                with self.subTest(mime=mime, mode=mode), \
                        mock.patch.object(image_description, 'create_llm', return_value=llm), \
                        mock.patch.object(route, 'upload_conversation_photo', return_value='test/image') as upload, \
                        mock.patch.object(route.dev_db, 'create_image', side_effect=self.record) as create:
                    if mode == 'base64':
                        response = self.client.post('/v1/images/base64', json={
                            'external_user_id': 'test-user', 'generate_description': True,
                            'base64_data': f'data:{mime};base64,{base64.b64encode(raw).decode()}',
                        })
                    else:
                        response = self.client.post('/v1/images', data={
                            'external_user_id': 'test-user', 'generate_description': 'true',
                        }, files={'file': ('test.png' if mime == 'image/png' else 'test.jpg', raw, mime)})
                self.assertEqual(response.status_code, 201, response.text)
                self.assertEqual(json.loads(response.json()['description'])['text'], ['TEST 37'])
                self.assertEqual(upload.call_args.kwargs['image_data'], raw)
                self.assertEqual(create.call_args.kwargs['developer_id'], 'test-developer')
                self.assertEqual(create.call_args.kwargs['external_user_id'], 'test-user')

    def test_optional_description_failure_preserves_uploaded_image(self):
        with mock.patch.object(route, 'upload_conversation_photo', return_value='test/image'), \
                mock.patch.object(route.dev_db, 'create_image', side_effect=self.record), \
                mock.patch.object(route, 'describe_image_with_gemini', side_effect=RuntimeError('provider down')):
            response = self.client.post('/v1/images/base64', json={
                'external_user_id': 'test-user', 'generate_description': True,
                'base64_data': base64.b64encode(b'\x89PNG\r\n\x1a\nfixture').decode(),
            })
        self.assertEqual(response.status_code, 201)
        self.assertIsNone(response.json()['description'])

    def test_upload_without_description_makes_no_model_call(self):
        with mock.patch.object(route, 'upload_conversation_photo', return_value='test/image'), \
                mock.patch.object(route.dev_db, 'create_image', side_effect=self.record), \
                mock.patch.object(route, 'describe_image_with_gemini') as describe:
            response = self.client.post('/v1/images/base64', json={
                'external_user_id': 'test-user',
                'base64_data': base64.b64encode(b'\x89PNG\r\n\x1a\nfixture').decode(),
            })
        self.assertEqual(response.status_code, 201)
        describe.assert_not_called()


if __name__ == '__main__':
    unittest.main()
