"""
Centralized localization helpers for backend-side user-facing strings.

We keep the SOURCE OF TRUTH for user.language at:
  developer_data/{developer_id}/users/{external_user_id}.language

This module owns the static (non-LLM) string lookups for short notification
titles / bodies / fallback labels keyed by language code. LLM prompts should
keep their English skeleton and just append a "Respond in {language}" hint
via `language_name_for_prompt`.

Language codes follow BCP-47 lower-case (e.g. 'zh', 'zh-cn', 'en', 'ja').
"""

from datetime import date
from typing import Optional, Tuple, List, Literal


def normalize_language_code(language_code: Optional[str]) -> str:
    """Normalize a language code to lower-case; default to 'en' if empty."""
    if not language_code:
        return 'en'
    return language_code.lower()


def base_language(language_code: Optional[str]) -> str:
    """Return the base language without region suffix (e.g. 'zh' from 'zh-CN')."""
    return normalize_language_code(language_code).split('-')[0]


# user.language 里存在两个不是语言的取值：'auto'（转录自动识别，App 的默认档）和
# 'multi'（多语言）。它们不能进 language_name_for_prompt——那个函数找不到就原样返回
# 代码，于是 prompt 里会出现 "Respond in auto." 这种指令，模型只能猜，实际上都退化
# 成英文输出。这类取值的正确语义是「跟着内容本身的语言走」，不是某个具体语言。
_UNSPECIFIED_LANGUAGE_CODES = {'auto', 'multi'}


def is_language_unspecified(language_code: Optional[str]) -> bool:
    """True 表示用户没有指定具体语言（'auto' / 'multi'），输出应跟随内容语言。"""
    return normalize_language_code(language_code) in _UNSPECIFIED_LANGUAGE_CODES


# ---------------------------------------------------------------------------
# Human-readable language names used to tag LLM prompts. Kept short and
# recognizable. Values are passed verbatim into "Respond in <name>." hints.
# ---------------------------------------------------------------------------

_LANGUAGE_NAMES = {
    'zh': 'Chinese (中文)',
    'zh-cn': 'Simplified Chinese (简体中文)',
    'zh-tw': 'Traditional Chinese (繁體中文)',
    'ja': 'Japanese (日本語)',
    'ko': 'Korean (한국어)',
    'es': 'Spanish (Español)',
    'fr': 'French (Français)',
    'de': 'German (Deutsch)',
    'pt': 'Portuguese (Português)',
    'it': 'Italian (Italiano)',
    'ru': 'Russian (Русский)',
    'ar': 'Arabic (العربية)',
    'hi': 'Hindi (हिन्दी)',
    'vi': 'Vietnamese (Tiếng Việt)',
    'th': 'Thai (ไทย)',
    'id': 'Indonesian (Bahasa Indonesia)',
    'nl': 'Dutch (Nederlands)',
    'pl': 'Polish (Polski)',
    'tr': 'Turkish (Türkçe)',
    'en': 'English',
}


def language_name_for_prompt(language_code: Optional[str]) -> str:
    """Return a human-readable language name suitable for an LLM prompt.

    Falls back to the raw code if unknown so the prompt still nudges the LLM
    correctly even for languages not in our table.
    """
    code = normalize_language_code(language_code)
    if code in _LANGUAGE_NAMES:
        return _LANGUAGE_NAMES[code]
    base = base_language(code)
    if base in _LANGUAGE_NAMES:
        return _LANGUAGE_NAMES[base]
    return code or 'English'


def llm_output_language_instruction(language_code: Optional[str]) -> str:
    """Single-line instruction appended to LLM prompts to enforce output language.

    Returns an empty string for English so we keep prompts clean by default.
    """
    code = normalize_language_code(language_code)
    if code in ('en', '') or base_language(code) == 'en':
        return ''
    if is_language_unspecified(code):
        # 'auto' / 'multi' 不是语言，不能拼进 "Respond in ..."（会变成 "Respond in
        # auto."）。改成跟随输入语言，这也正是这两个取值的本意。
        return "Respond in the same language as the input. Do not translate it into another language."
    return f"Respond in {language_name_for_prompt(code)}. Do not respond in English."


# ---------------------------------------------------------------------------
# Short notification copy lookups.
#
# These are user-facing strings, not LLM prompts. Add a new language by adding
# an entry to each dict; missing languages fall back to English.
# ---------------------------------------------------------------------------

# Morning push body pool — exactly 5 variants per language, rotated by
# day-of-year so all users see the same line on the same day. Title stays as
# the brand "Memorion" across the day.
_MORNING_ALERT_TITLE = 'Memorion'

_MORNING_ALERT_BODIES = {
    'zh': [
        '早安 · 今天也会是能被记得的一天。',
        '新的一天开始了 · 试着说出第一个浮现的想法。',
        '早安 · 今天有什么想留下的瞬间？',
        '把今天值得回味的对话交给 Memorion。',
        '一个新的早晨 · 你的故事正在被认真听见。',
    ],
    'zh-cn': [
        '早安 · 今天也会是能被记得的一天。',
        '新的一天开始了 · 试着说出第一个浮现的想法。',
        '早安 · 今天有什么想留下的瞬间？',
        '把今天值得回味的对话交给 Memorion。',
        '一个新的早晨 · 你的故事正在被认真听见。',
    ],
    'zh-tw': [
        '早安 · 今天也會是能被記得的一天。',
        '新的一天開始了 · 試著說出第一個浮現的想法。',
        '早安 · 今天有什麼想留下的瞬間？',
        '把今天值得回味的對話交給 Memorion。',
        '一個新的早晨 · 你的故事正在被認真聽見。',
    ],
    'ja': [
        'おはよう · 今日も思い出に残る一日になりますように。',
        '新しい一日のはじまり · 浮かんできた最初の言葉を口にしてみて。',
        'おはよう · 今日は何を残しておきたい？',
        '味わい深い会話は Memorion におまかせ。',
        '新しい朝 · あなたの物語はちゃんと聴かれているよ。',
    ],
    'ko': [
        '좋은 아침 · 오늘도 기억할 만한 하루가 될 거예요.',
        '새로운 하루의 시작 · 떠오르는 첫 생각을 말해 봐요.',
        '좋은 아침 · 오늘은 어떤 순간을 남기고 싶나요?',
        '오늘의 의미 있는 대화는 Memorion에 맡겨 주세요.',
        '새로운 아침 · 당신의 이야기가 잘 들리고 있어요.',
    ],
    'es': [
        'Buenos días · hoy también será un día que valga la pena recordar.',
        'Empieza un nuevo día · prueba a decir lo primero que se te ocurra.',
        'Buenos días · ¿qué momento quieres guardar hoy?',
        'Deja que Memorion conserve las conversaciones de hoy.',
        'Una mañana nueva · tu historia se está escuchando con calma.',
    ],
    'fr': [
        'Bonjour · que cette journée mérite, elle aussi, d\'être retenue.',
        'Une nouvelle journée commence · essaie de dire la première idée qui vient.',
        'Bonjour · quel moment voudrais-tu garder aujourd\'hui ?',
        'Laisse Memorion conserver les conversations qui en valent la peine.',
        'Un matin nouveau · ton histoire est écoutée avec soin.',
    ],
    'de': [
        'Guten Morgen · auch heute wird ein Tag, der erinnert werden darf.',
        'Ein neuer Tag beginnt · sag den ersten Gedanken laut, der dir kommt.',
        'Guten Morgen · welchen Moment möchtest du heute festhalten?',
        'Überlass Memorion die Gespräche, die du später noch hören willst.',
        'Ein neuer Morgen · deine Geschichte wird wirklich gehört.',
    ],
    'pt': [
        'Bom dia · que hoje também seja um dia digno de lembrança.',
        'Um novo dia começa · diga em voz alta o primeiro pensamento.',
        'Bom dia · qual momento você quer guardar hoje?',
        'Deixe o Memorion preservar as conversas que valem a pena.',
        'Uma nova manhã · sua história está sendo ouvida com atenção.',
    ],
    'it': [
        'Buongiorno · anche oggi sarà un giorno che vale ricordare.',
        'Inizia un nuovo giorno · prova a dire il primo pensiero che ti viene.',
        'Buongiorno · quale momento vuoi conservare oggi?',
        'Lascia che Memorion custodisca le conversazioni di oggi.',
        'Un nuovo mattino · la tua storia viene ascoltata davvero.',
    ],
    'ru': [
        'Доброе утро · пусть и этот день останется в памяти.',
        'Новый день начался · скажи вслух первую мысль, которая пришла.',
        'Доброе утро · какой момент ты хочешь сохранить сегодня?',
        'Доверь Memorion разговоры, к которым захочется вернуться.',
        'Новое утро · твою историю слышат внимательно.',
    ],
    'vi': [
        'Chào buổi sáng · hôm nay cũng sẽ là một ngày đáng nhớ.',
        'Một ngày mới bắt đầu · thử nói ra ý nghĩ đầu tiên xuất hiện.',
        'Chào buổi sáng · hôm nay bạn muốn giữ lại khoảnh khắc nào?',
        'Hãy để Memorion lưu giữ những cuộc trò chuyện đáng nhớ.',
        'Một buổi sáng mới · câu chuyện của bạn đang được lắng nghe.',
    ],
    'th': [
        'อรุณสวัสดิ์ · ขอให้วันนี้เป็นอีกวันที่ควรจดจำ',
        'วันใหม่เริ่มแล้ว · ลองพูดความคิดแรกที่ผุดขึ้นมาดูสิ',
        'อรุณสวัสดิ์ · วันนี้อยากเก็บช่วงเวลาแบบไหนเอาไว้?',
        'ปล่อยให้ Memorion เก็บบทสนทนาที่น่าจดจำของวันนี้',
        'เช้าใหม่ · เรื่องราวของคุณกำลังถูกรับฟังอย่างตั้งใจ',
    ],
    'id': [
        'Selamat pagi · semoga hari ini pun layak untuk diingat.',
        'Hari baru dimulai · coba ucapkan pikiran pertama yang muncul.',
        'Selamat pagi · momen apa yang ingin kamu simpan hari ini?',
        'Biarkan Memorion menjaga percakapan yang berharga hari ini.',
        'Pagi yang baru · ceritamu sedang didengarkan dengan saksama.',
    ],
    'nl': [
        'Goedemorgen · ook vandaag wordt een dag om te onthouden.',
        'Een nieuwe dag begint · zeg hardop de eerste gedachte die opkomt.',
        'Goedemorgen · welk moment wil je vandaag bewaren?',
        'Laat Memorion de gesprekken bewaren die de moeite waard zijn.',
        'Een nieuwe ochtend · je verhaal wordt echt gehoord.',
    ],
    'pl': [
        'Dzień dobry · niech ten dzień też będzie wart zapamiętania.',
        'Zaczyna się nowy dzień · powiedz na głos pierwszą myśl, jaka się pojawi.',
        'Dzień dobry · jaką chwilę chcesz dziś zachować?',
        'Zostaw Memorion rozmowy, do których zechcesz wrócić.',
        'Nowy poranek · twoja historia jest naprawdę słuchana.',
    ],
    'tr': [
        'Günaydın · bugün de hatırlanmaya değer bir gün olsun.',
        'Yeni bir gün başlıyor · aklına ilk gelen düşünceyi sesli söyle.',
        'Günaydın · bugün hangi anı saklamak istiyorsun?',
        'Bugünün anlamlı sohbetlerini Memorion saklasın.',
        'Yeni bir sabah · hikâyen dikkatle dinleniyor.',
    ],
    'ar': [
        'صباح الخير · ليكن اليوم أيضاً يوماً يستحق التذكر.',
        'يومٌ جديد يبدأ · جرّب أن تقول أول فكرة خطرت ببالك.',
        'صباح الخير · أي لحظة تودّ الاحتفاظ بها اليوم؟',
        'دع Memorion يحفظ محادثات اليوم التي تستحق العودة إليها.',
        'صباحٌ جديد · قصتك تُسمَع باهتمام.',
    ],
    'hi': [
        'सुप्रभात · आज का दिन भी याद रखने लायक हो।',
        'नया दिन शुरू हुआ · दिमाग में आया पहला ख़याल बोल कर देखो।',
        'सुप्रभात · आज का कौन सा पल सहेजना चाहोगे?',
        'आज की कीमती बातचीतें Memorion पर छोड़ दो।',
        'एक नई सुबह · तुम्हारी कहानी ध्यान से सुनी जा रही है।',
    ],
    'en': [
        'Good morning · may today be another day worth remembering.',
        'A new day begins · try saying the first thought that comes to mind.',
        'Good morning · what moment do you want to keep from today?',
        'Let Memorion hold on to the conversations worth revisiting.',
        'A new morning · your story is being heard, attentively.',
    ],
}


def _today_day_of_year() -> int:
    return date.today().timetuple().tm_yday


def get_localized_morning_alert(
    language_code: Optional[str],
    day_index: Optional[int] = None,
) -> Tuple[str, str]:
    """Return (title, body) for the morning push, localized to user.language.

    Body rotates daily across a fixed pool of 5 variants per language; same
    day = same body for all users. Pass ``day_index`` to override the rotation
    (useful for tests or backfills); defaults to today's day-of-year (1..366).
    """
    code = normalize_language_code(language_code)
    bodies = (
        _MORNING_ALERT_BODIES.get(code)
        or _MORNING_ALERT_BODIES.get(base_language(code))
        or _MORNING_ALERT_BODIES['en']
    )
    idx = (day_index if day_index is not None else _today_day_of_year()) % len(bodies)
    return _MORNING_ALERT_TITLE, bodies[idx]


# ---------------------------------------------------------------------------
# Daily summary label used both for OS push title and the in-content heading.
# Keeping a single mapping avoids title/header drift across push + summary text.
# ---------------------------------------------------------------------------

_DAILY_SUMMARY_LABEL = {
    'zh': '今日亮点',
    'zh-cn': '今日亮点',
    'zh-tw': '今日亮點',
    'ja': '今日のハイライト',
    'ko': '오늘의 하이라이트',
    'es': 'Momentos destacados de hoy',
    'fr': 'Temps forts du jour',
    'de': 'Highlights des Tages',
    'pt': 'Destaques do dia',
    'it': 'Momenti salienti di oggi',
    'ru': 'Главное за день',
    'ar': 'أبرز ما في اليوم',
    'hi': 'आज की मुख्य बातें',
    'vi': 'Điểm nhấn trong ngày',
    'th': 'ไฮไลต์ของวันนี้',
    'id': 'Sorotan hari ini',
    'nl': 'Hoogtepunten van vandaag',
    'pl': 'Najważniejsze momenty dnia',
    'tr': 'Günün öne çıkanları',
    'en': 'Daily Highlights',
}


def _lookup_daily_summary_label(language_code: Optional[str]) -> str:
    code = normalize_language_code(language_code)
    if code in _DAILY_SUMMARY_LABEL:
        return _DAILY_SUMMARY_LABEL[code]
    base = base_language(code)
    if base in _DAILY_SUMMARY_LABEL:
        return _DAILY_SUMMARY_LABEL[base]
    return _DAILY_SUMMARY_LABEL['en']


def get_localized_daily_summary_title(language_code: Optional[str]) -> str:
    return _lookup_daily_summary_label(language_code)


def get_localized_daily_summary_header(language_code: Optional[str]) -> str:
    return _lookup_daily_summary_label(language_code)


# ---------------------------------------------------------------------------
# Conversation fallback titles (when LLM structuring fails).
# ---------------------------------------------------------------------------

_FALLBACK_CONVERSATION_TITLE = {
    'zh': '对话',
    'zh-cn': '对话',
    'zh-tw': '對話',
    'ja': '会話',
    'ko': '대화',
    'es': 'Conversación',
    'fr': 'Conversation',
    'de': 'Gespräch',
    'pt': 'Conversa',
    'it': 'Conversazione',
    'ru': 'Разговор',
    'vi': 'Cuộc trò chuyện',
    'th': 'บทสนทนา',
    'id': 'Percakapan',
    'nl': 'Gesprek',
    'pl': 'Rozmowa',
    'tr': 'Konuşma',
    'ar': 'محادثة',
    'hi': 'बातचीत',
    'en': 'Conversation',
}


def get_fallback_conversation_title(language_code: Optional[str]) -> str:
    code = normalize_language_code(language_code)
    if code in _FALLBACK_CONVERSATION_TITLE:
        return _FALLBACK_CONVERSATION_TITLE[code]
    base = base_language(code)
    if base in _FALLBACK_CONVERSATION_TITLE:
        return _FALLBACK_CONVERSATION_TITLE[base]
    return _FALLBACK_CONVERSATION_TITLE['en']


# ---------------------------------------------------------------------------
# EIR / emotional-care fallback messages (used if LLM generation fails).
# ---------------------------------------------------------------------------

_EIR_FALLBACK_MESSAGE = {
    'zh': '我注意到你刚才的对话。无论发生什么，我都在这里陪着你。',
    'ja': 'あなたの会話に気づきました。何があっても、私はここにいます。',
    'ko': '방금 대화를 확인했어요. 무슨 일이 있든 곁에 있을게요.',
    'es': 'Vi tu conversación reciente. Pase lo que pase, estoy aquí.',
    'fr': 'J\'ai vu ta dernière conversation. Quoi qu\'il arrive, je suis là.',
    'de': 'Ich habe dein Gespräch bemerkt. Was auch immer passiert, ich bin für dich da.',
    'pt': 'Notei sua conversa recente. Aconteça o que acontecer, estou aqui.',
    'ru': 'Я заметил ваш разговор. Что бы ни случилось, я рядом.',
    'vi': 'Mình đã thấy cuộc trò chuyện của bạn. Dù chuyện gì xảy ra, mình vẫn ở đây.',
    'en': "I noticed your recent conversation. Whatever you're going through, I'm here for you.",
}


def get_eir_fallback_message(language_code: Optional[str]) -> str:
    code = normalize_language_code(language_code)
    if code in _EIR_FALLBACK_MESSAGE:
        return _EIR_FALLBACK_MESSAGE[code]
    base = base_language(code)
    if base in _EIR_FALLBACK_MESSAGE:
        return _EIR_FALLBACK_MESSAGE[base]
    return _EIR_FALLBACK_MESSAGE['en']


# ---------------------------------------------------------------------------
# Unified language resolution with multi-layer fallback for push notifications
# ---------------------------------------------------------------------------

LanguageSource = Literal['user_pref', 'conversation_inferred', 'default']


def get_user_effective_language(
    developer_id: Optional[str],
    uid: str,
    fallback_conversations: Optional[List[dict]] = None,
) -> Tuple[str, LanguageSource]:
    """
    Resolve user's effective language with multi-layer fallback strategy.

    Fallback priority:
    1. user.language from Firestore (developer_data/{dev_id}/users/{uid}.language)
    2. language field from recent conversations (if fallback_conversations provided)
    3. default 'en'

    Returns:
        (language_code, source) where source is one of:
        - 'user_pref': from Firestore user.language field
        - 'conversation_inferred': from conversation history
        - 'default': fallback to English

    Args:
        developer_id: Developer ID for Firestore lookup (None for legacy users collection)
        uid: User ID (external_user_id)
        fallback_conversations: Optional list of conversation dicts to infer language from
    """
    # Try user preference first
    if developer_id:
        try:
            import database.developer_data as dev_db
            user_lang = dev_db.get_user_language(developer_id, uid)
            if user_lang:
                return normalize_language_code(user_lang), 'user_pref'
        except Exception:
            pass

    # Try inferring from conversations
    if fallback_conversations:
        for conv in fallback_conversations:
            lang = conv.get('language')
            if lang:
                return normalize_language_code(lang), 'conversation_inferred'

    # Default fallback
    return 'en', 'default'
