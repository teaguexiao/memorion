"""Keep internal media placeholders out of user-facing timeline projections."""

MEDIA_RECORDING_TITLE = '[Media Recording]'


def summary_marks_media(structured) -> bool:
    title = structured.get('title') if isinstance(structured, dict) else getattr(structured, 'title', None)
    return (title or '').strip().strip('[]').strip().casefold() == 'media recording'


def conversation_is_hidden(conversation: dict) -> bool:
    return bool(conversation.get('discarded') or summary_marks_media(conversation.get('structured')))
