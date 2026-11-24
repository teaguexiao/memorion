"""Execute the recovery function without starting the unrelated audio/VAD stack."""
import ast
from copy import deepcopy
from datetime import datetime, timezone
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

os.environ.setdefault('OPENAI_API_KEY', 'test')
os.environ.setdefault('OPENROUTER_API_KEY', 'test')

from models.conversation import Structured
from utils.llm.conversation_processing import summary_marks_media


class VocabularyRecoveryTests(unittest.TestCase):
    def test_recovery_uses_scoped_vocabulary_and_keeps_source_transcript(self):
        source = Path(__file__).resolve().parents[1] / 'routers/developer_conversations.py'
        node = next(n for n in ast.parse(source.read_text()).body
                    if isinstance(n, ast.FunctionDef) and n.name == '_revisit_user_dependent_verdicts')
        db = Mock()
        db.get_user_language.return_value = 'zh'
        db.get_user_time_zone.return_value = 'Asia/Shanghai'
        db.get_vocabulary_terms.return_value = ['姚晨']
        structure = Mock(return_value=Structured(
            title='感谢朋友', overview='感谢多年的陪伴', first_person_observation='我记住了这份情谊',
            highlights=['姚晨，没有你，就没有今天的我。'],
        ))
        namespace = dict(dev_db=db, get_transcript_structure=structure,
                         summary_marks_media=summary_marks_media,
                         _apply_action_item_gate=Mock())
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), 'exec'), namespace)
        segments = [{'is_user': True, 'speaker_id': 0, 'text': '瑶晨，没有你，就没有今天的我。'}]
        original = deepcopy(segments)
        conversation = dict(id='synthetic-recovery', discarded=True,
                            started_at=datetime(2026, 10, 13, tzinfo=timezone.utc),
                            transcript_segments=segments, structured={})
        vector = Mock()
        with patch.dict(sys.modules, {'utils.conversations.process_conversation':
                                     SimpleNamespace(save_vector_from_dict=vector)}):
            namespace[node.name]('developer-a', 'user-a', conversation, segments)
        vector.assert_called_once()
        db.get_vocabulary_terms.assert_called_once_with('developer-a', 'user-a')
        self.assertEqual(structure.call_args.kwargs['vocabulary_terms'], ['姚晨'])
        self.assertIn(original[0]['text'], structure.call_args.kwargs['transcript'])
        self.assertEqual(segments, original)
        self.assertEqual(conversation['transcript_segments'], original)
        self.assertFalse(conversation['discarded'])
        self.assertEqual(db.update_conversation_discarded.call_args.kwargs['highlights'],
                         ['姚晨，没有你，就没有今天的我。'])
        self.assertEqual(conversation['structured']['highlights'],
                         db.update_conversation_discarded.call_args.kwargs['highlights'])


if __name__ == '__main__':
    unittest.main()
