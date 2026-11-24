from langchain_core.prompts import ChatPromptTemplate

# *
# INSTRUCTIONS
# Content in strings between {}, is a placeholder/variable, that is replaced when the prompt is used.
# Never remove {format_instructions} variable, as this is what outputs an object instead of a string/json, thus breaking the app.
# *


extract_memories_prompt_text = '''
    You maintain the long-term personal profile of {user_name}.

    From the conversation transcript below, extract ONLY facts that are worth
    remembering about {user_name} as a person, forever. These facts are shown to
    {user_name} in their profile ("What it remembers about you") and are fed to an
    AI companion as long-term memory. A wrong or trivial fact damages trust far
    more than a missing one.

    Be strict: extract 0, 1, or at most 2 facts. Many conversations contain none,
    and an empty list is a perfectly good answer — never pad the list. But when the
    transcript does plainly reveal something lasting about {user_name}'s life,
    capture it; silently dropping a genuine fact is also a failure.

    ## How to read the transcript

    The recording comes from a wearable device that {user_name} carries all day, so
    every conversation happens in {user_name}'s presence — with family, colleagues,
    or friends.

    Speaker attribution is unreliable: lines are often labelled "Speaker 1" /
    "Speaker 2" even when {user_name} is speaking. **Do not try to work out who
    said which line, and do not refuse to extract a fact just because the speaker
    is unlabelled.**

    Judge instead by what the fact is about. It counts as {user_name}'s profile
    when it describes {user_name}'s own life circle — their household and family,
    their workplace and projects, where they live, their routine — even if another
    person in the room said it. It does NOT count when it is a topic the
    conversation merely discussed (news, history, products, celebrities, gossip),
    or a private matter of someone unconnected to {user_name}'s daily life.

    ## ONLY these six kinds of facts may be extracted (strict whitelist)

    1. **Identity & situation** — age, hometown, city lived in, health condition,
       marital status, language(s) spoken.
       e.g. "You live in Baoshan, Shanghai."
    2. **Lasting relationships** — family members and close, recurring people,
       including their names, roles, and ages.
       e.g. "You have a young child who plays video games."
    3. **Work & long-running projects** — occupation, employer, role, and
       projects or responsibilities that span weeks or longer. If {user_name} runs
       a company, what that company *is* and what it builds counts here.
       e.g. "You are building an AI wearable product."
    4. **Stable preferences** — foods, activities, tools, or styles {user_name}
       consistently likes or dislikes. A single instance is not a preference.
       e.g. "You dislike cilantro."
    5. **Recurring habits & routines** — things {user_name} does repeatedly, on a
       schedule, or as a rule.
       e.g. "You usually get off work after 6pm."
    6. **Goals & values** — what {user_name} is working toward or cares about,
       when stated plainly and not just in passing.
       e.g. "You want AI to handle most of your product work."

    If a candidate does not clearly land in one of these six, it is NOT a fact.

    ## NEVER extract these (the most common mistakes)

    - **World / technical / product knowledge.** e.g. "AWS certificates are free
      and auto-renew", "Whisper has the best WER among open models", "the 2026
      World Cup is co-hosted by three countries", "Apple's PE ratio is around 20".
      This is conversation content, not {user_name}'s profile.
    - **Meeting notes, decisions, and to-dos.** e.g. "discussed GPU utilization",
      "the architecture diagram will be revised before migration", "will discuss
      the deployment on Thursday", "plans to create a sub-agent for the course
      material". Tasks and plans belong to action items, not to the profile.
    - **How a team or company is run — its plumbing.** This is the single most
      common source of junk in this profile, and it is tempting precisely because
      every such sentence is true and work-related. Never extract which tools,
      vendors, subscriptions, cloud services or repos a team runs on; how big its
      data, bill, office or headcount is; where it sits; which metrics or
      priorities it is steering by; which feature, phase or sprint it is shipping
      this week; or what it concluded in a meeting. e.g. "the team uses Feishu for
      work communication", "the team's RDS data is about 10-20 GB", "the team
      switched to a $15/month Cloudflare plan", "the office moved to MixC World",
      "the investment team has about 20 people", "they are developing the seventh
      phase of the project", "the startup prioritizes revenue over DAU". None of
      these tell you anything about {user_name} as a person. Only what
      {user_name}'s own company *is and builds* belongs here (whitelist item 3).
    - **Other people's business.** e.g. "Speaker 2 has poor hearing", "a
      colleague's girlfriend was upset", "the auntie took the lunchbox early",
      "a coworker is getting married". Only include another person when the fact
      defines a lasting relationship of {user_name} (whitelist item 2).
    - **One-off actions, today's schedule, and small talk.** e.g. "grill the meat
      longer", "bought 5 RMB of snacks", "will take medicine", "chose the Xinjiang
      restaurant", "is driving home with 200km left".
    - **Opinions, advice, and aphorisms stated by anyone**, including {user_name}
      and including sound professional recommendations. e.g. "knowledge can be a
      curse", "listening to English music daily improves speaking", "short videos
      are the next generation's medium", "recommends ECS or EKS for 24/7 agent
      infrastructure", "Kero CLI can significantly improve team operations",
      "reserve 10% of your energy while singing for better control". What someone
      thinks one *ought to do* is not a fact about their life.
    - **Trivia that is true but tells you nothing about the person.** Specs,
      capacities, prices or settings of a device or account; a phrase or factoid
      someone picked up; a single toy or object; a minor injury; a bit of
      housekeeping. e.g. "the audio hardware has three-day battery life",
      "learned that Ultraman Tregear is a dark-side character", "the child's toy
      car is modeled on a real van", "a finger injury once made chopsticks hard",
      "consolidates accounts to avoid multiple MFAs". Ask: if you introduced
      {user_name} to a stranger in a few sentences, would this earn a place? If
      not, leave it out.
    - **Anything guessed.** If the transcript does not support it plainly, it does
      not exist. Never invent a name, number, or relationship.
    - **Anything already known** (see the existing facts below), including
      rephrasings and near-duplicates of it, or of another fact in this same output.

    ## Before you answer, self-check each candidate

    For every fact you are about to output, answer these three questions
    independently. They are separate tests: a fact must pass ALL THREE. Most
    rejected facts fail because one strong "yes" was allowed to carry the others.

    **(1) Whose life is this about?** Read your sentence literally and find its
    subject. Ask it of the *person* the sentence is about, not of the word "you":
    keep it only if that person is {user_name}, a member of their household, or
    {user_name}'s own company *as a venture* (what it is, what it builds). Reject
    it if the subject is a named colleague, a manager, a client, a client's
    company, a friend, a public figure, or an acquaintance — *even when they work
    with {user_name}*, and even when {user_name} would find it interesting. Reject
    it if there is no person at all (a product, a technology, a market, a metric, a
    rule, another company). Reject it if it is the internal running of a team or
    company rather than a person.
      - "Kevin is now a Product Manager for Genetic AI" → a colleague. Reject.
      - "Amazon Q Developer is merging into Amazon Q" → no person. Reject.
      - "The client migrated to microservices" → a client. Reject.
      - "The team uses Feishu for work communication" → org plumbing. Reject.
      - "Your startup builds AI hardware" → the venture itself. Keep.
      - "Your daughter is in second grade" → your household. Keep.

    **(2) Is it lasting?** Keep it only if it is a stable trait, role,
    relationship, possession, taste, repeated routine, or a project {user_name} is
    building over months — something still true next month with nobody doing
    anything. Reject a task or decision ("applying for a licence"), a single
    occurrence ("hosted a workshop on Feb 7", "achieved 103 sign-ups in Q3"), a
    momentary state or piece of news ("the iPad is broken", "headcount rose to 10",
    "two roles merged"), and anything that is advice or a general principle rather
    than a fact about a life.

    **(3) Would it earn a place in an introduction?** Imagine introducing
    {user_name} to a stranger in a handful of sentences. Keep the fact only if it
    would make the cut — identity, origin, home, health, family, work, what they
    are building, their money, a real taste or habit, a goal they hold. Reject
    trivia that is true but weightless: a device spec, a phrase picked up, one toy,
    a small injury, a bit of admin, or a self-flattering generality that would fit
    almost anyone ("actively invites feedback").

    A "yes" to one question never rescues a "no" to another. If any answer is no or
    uncertain, delete the fact.

    ## Output rules

    - **At most 2 facts.** Output only those that survive the self-check — if none
      do, return an empty list rather than the best of a bad set.
    - **Address {user_name} in the SECOND PERSON ("you" / "your").** These
      sentences are shown back to {user_name} in their own profile, next to
      sections that already speak to them directly, so a third-person fact reads
      like someone else's notes about them. Write "You live in Baoshan, Shanghai."
      — never "{user_name} lives in Baoshan, Shanghai." and never "The user lives
      in Baoshan, Shanghai."
      - Do NOT start the sentence with {user_name}'s name, and do not refer to
        {user_name} in the third person anywhere in the sentence.
      - Other people stay in the third person, described by their relation to
        {user_name}: "Your daughter plays video games.", not "Emma plays video
        games." Keep their names only when the name itself is the fact ("Your
        daughter is called Emma.").
      - This is about how the sentence is worded, not about which facts qualify.
        The whitelist and self-check above still judge whether something is a
        fact about {user_name} at all — reword only what survives them.
    - One short sentence each, stated objectively. Never use he/she/his/her for
      {user_name} ({user_name}'s gender is unknown) — with second person there is
      no reason to.
    - **Language.** Write each fact in {user_name}'s own profile language — see the
      language instruction at the very end of this prompt, which overrides this
      bullet if they disagree. These sentences are displayed back to {user_name} in
      their profile, so a fact in the wrong language reads like someone else's
      notes. This is independent of the transcript's language and of the language
      of these instructions: do NOT default to English just because this prompt is
      in English, and do not follow the transcript's language when the instruction
      names a specific one. Translate units and measure words too; keep proper
      nouns, product names, and people's names as they appear.
    - `category`:
      - `system` — objective profile: identity, job, location, family, health,
        long-running projects or responsibilities.
      - `interesting` — preferences and character: likes, dislikes, habits,
        values, goals, strengths.
      - When unsure, use `system`.
    - Output only the facts. No explanations, no commentary.

    **Facts already known about {user_name} (DO NOT REPEAT OR REPHRASE ANY)**:
    ```
    {memories_str}
    ```

    **Conversation transcript**:
    ```
    {conversation}
    ```

    {output_language_instruction}
    {format_instructions}
    '''.replace(
    '    ', ''
).strip()

extract_memories_prompt = ChatPromptTemplate.from_messages([extract_memories_prompt_text])

extract_memories_text_content_prompt_text = '''
    You are an expert at extracting both (1) new facts about {user_name} and (2) new learnings or insights relevant to {user_name}.

    You will be provided with:
    1. A list of existing facts about {user_name} and learnings {user_name} already knows (to avoid repetition).
    2. A text content from which you will extract new information.

    ---

    ## Part 1: Extract New Facts About {user_name}

    **Categories for Facts**:
    - **core**: Fundamental personal information like age, city of residence, marital status, and health.
    - **hobbies**: Activities {user_name} enjoys in their leisure time.
    - **lifestyle**: Details about {user_name}'s way of living, daily routines, or habits.
    - **interests**: Subjects or areas that {user_name} is curious or passionate about.
    - **habits**: Regular practices or tendencies of {user_name}.
    - **work**: Information related to {user_name}'s occupation, job, or professional life.
    - **skills**: Abilities or expertise that {user_name} possesses.
    - **other**: Any other relevant information that doesn't fit into the above categories.

    **Tags for Facts**:
    - **core**: Basic personal info (e.g., age, city of residence, marital status, health).
    - **hobbies**: Leisure activities {user_name} enjoys.
    - **lifestyle**: Ways of living, daily routines, or habits.
    - **interests**: Topics or areas that pique {user_name}’s curiosity or passion.
    - **habits**: Regular practices or tendencies.
    - **work**: Professional or job-related details.
    - **skills**: Abilities or expertise.

    **Requirements**:
    1. **Relevance & Non-Repetition**: Include only new facts not already known from the “existing facts.”
    2. **Second Person**: Address {user_name} as “you” / “your”, never by name and never in the third person — these facts are shown back to {user_name} in their own profile. e.g. “You live in Paris.”, not “{user_name} lives in Paris.” Other people stay in the third person, described by their relation to {user_name} (“your manager”, “your daughter”).
    3. **Conciseness**: Clearly and succinctly present each fact.
    4. **Inferred Information**: Include logical inferences supported by the text.
    5. **Gender Neutrality**: Never use “he” or “she” for {user_name}, whose gender is unknown — with second person there is no reason to.
    6. **Limit**: Identify up to 100 new facts. If there are none, output an empty list.

    ---

    ## Part 2: Extract New Learnings or Insights

    You will also identify up to 100 valuable learnings, facts, or insights that {user_name} can gain from the text. These can be about the world, life lessons, motivational ideas, historical or scientific facts, or practical advice.

    **Categories for Learnings**:
    - **learnings**: Any learning the user has.

    **Tags for Learnings**:
    - **life_lessons**: General wisdom or principles for living.
    - **world_facts**: Interesting information about geography, cultures, or global matters.
    - **motivational_insights**: Statements or ideas that can inspire or encourage.
    - **historical_facts**: Notable events or information from the past.
    - **scientific_facts**: Insights related to science or technology.
    - **practical_advice**: Tips or recommendations that can be applied in daily life.

    **Requirements**:
    1. **Relevance & Non-Repetition**: Include only new insights not already in the user’s known learnings.
    2. **Conciseness**: State each learning clearly and briefly, e.g. “It’s beneficial to exercise in the morning.”
    3. **Inferred Information**: Provide insights that are implied or can be logically deduced from the text.
    4. **First-Person (Optional)**: If it feels natural, present certain learnings in a first-person style (e.g., “I should …”).
    5. **Limit**: Identify up to 100 new learnings. If there are none, output an empty list.

    ---

    ## Existing Knowledge (Do Not Repeat)

    **Existing facts about {user_name} and learnings {user_name} already has**:**:

    ```
    {memories_str}
    ```

    ---

    ## Content to Analyze

    {text_content}

    ---

    ## Output Instructions

    1. Provide **one** lists in your final output:
       - **New Facts About {user_name} and New Learnings or Insights** (up to 100)

    2. **Do not** include any additional commentary or explanation. Only list the extracted items.

    If no new facts or learnings are found, output empty lists accordingly.

    {output_language_instruction}
    {format_instructions}
    '''.replace(
    '    ', ''
).strip()

extract_memories_text_content_prompt = ChatPromptTemplate.from_messages(
    [extract_memories_text_content_prompt_text]
)


extract_memories_text_content_prompt_v1 = ChatPromptTemplate.from_messages(
    [
        '''
    You are an expert fact extractor. Your task is to analyze the {text_source} content and extract important facts about {user_name}.

    You will be provided with a text content from the {text_source} content, along with a list of existing facts about {user_name}. \
    Your task is to identify **new** facts about {user_name} if any, such as age, city of residence, marital status, health, friends' names, \
    occupation, allergies, preferences, interests, or any other important information.

    **Categories for Facts**:

    Each fact you provide should fall under one of the following categories:

    - **core**: Fundamental personal information like age, city of residence, marital status, and health.
    - **hobbies**: Activities {user_name} enjoys in their leisure time.
    - **lifestyle**: Details about {user_name}'s way of living, daily routines, or habits.
    - **interests**: Subjects or areas that {user_name} is curious or passionate about.
    - **habits**: Regular practices or tendencies of {user_name}.
    - **work**: Information related to {user_name}'s occupation, job, or professional life.
    - **skills**: Abilities or expertise that {user_name} possesses.
    - **other**: Any other relevant information that doesn't fit into the above categories.

    **Requirements for the facts you provide**:

    - **Relevance**: The facts should be pertinent and not repetitive or too similar to the existing facts about {user_name}. Aim for a broad range of information rather than excessive detail on specific points.
    - **Conciseness**: Present each fact clearly and succinctly in the format "{user_name} is 25 years old." or "{user_name} works as a software engineer."
    - **Inferred Information**: Include facts that are not only explicitly stated but also those that can be logically inferred from the conversation context and existing facts.
    - **Gender Neutrality**: Do not use gender-specific pronouns like "he," "she," "his," or "her," as {user_name}'s gender is unknown.
    - **Non-Repetition**: Ensure that none of the new facts repeat or closely mirror the existing facts.

    **Examples**:

    - "{user_name} is 28 years old and lives in New York City." (**core**)
    - "{user_name} has a friend named Martin who is a founder." (**core**)
    - "{user_name} enjoys hiking and photography during free time." (**hobbies**)
    - "{user_name} follows a vegetarian diet and practices yoga daily." (**lifestyle**)
    - "{user_name} is interested in artificial intelligence and machine learning." (**interests**)
    - "{user_name} reads a chapter of a book every night before bed." (**habits**)
    - "{user_name} works as a software engineer at a tech startup." (**work**)
    - "{user_name} is proficient in Python and Java programming languages." (**skills**)

    - "{user_name} has a pet dog named Max who is a golden retriever." (**other**)

    **Output Instructions**:

    - Identify up to 3 valuable **new** facts (max 2).
    - Before outputting a fact, ensure it is not already known about {user_name}.
    - If you do not find any new (different to the list of existing ones below) or new noteworthy facts, provide an empty list.
    - Do not include any explanations or additional text; only list the facts.

    **Existing facts you already know about {user_name} (DO NOT REPEAT ANY)**:
    ```
    {memories_str}
    ```

    **Text Content**:
    ```
    {text_content}
    ```
    {format_instructions}
    '''.replace(
            '    ', ''
        ).strip()
    ]
)


extract_learnings_prompt_text = '''
You are an insightful assistant tasked with extracting key learnings and valuable facts from conversations.

You will be provided with a conversation transcript or content that {user_name} has listened to.

Your task is to identify new facts or important learnings about the world, life, or any information that can make {user_name} more knowledgeable.

**Categories for Learnings**:

Each learning or fact you provide should fall under one of the following categories:

- **Life Lessons**: Important principles or lessons about life.
- **World Facts**: Interesting or significant facts about the world.
- **Motivational Insights**: Ideas or thoughts that can inspire or motivate.
- **Historical Facts**: Notable events or information from history.
- **Scientific Facts**: Knowledge about scientific discoveries or principles.
- **Practical Advice**: Useful tips or advice that can be applied in daily life.
- **Other**: Any other relevant information that doesn't fit into the above categories.

**Requirements for the learnings you provide**:

- **Relevance**: The learnings should be significant and useful to {user_name}.
- **Conciseness**: Present each learning clearly and succinctly.
- **Inferred Information**: Include learnings that are not only explicitly stated but also those that can be logically inferred from the conversation context.
- **First-Person Inclusion**: If applicable, frame the learnings in first person to make them more personal, e.g., "Every morning I should watch something motivational."
- **Non-Repetition**: Ensure that none of the new learnings repeat or closely mirror any existing knowledge that {user_name} already has.

**Examples**:

- "Students are an amazing target user because they are early adopters and numerous." (**World Facts**)
- "The second co-founder of Notion joined five years after the company started." (**Historical Facts**)
- "Finding a group of like-minded peers early is very important." (**Life Lessons**)
- "Every morning I should watch something motivational." (**Practical Advice**)

**Output Instructions**:

- Identify up to 5 valuable learnings or facts (maximum 5).
- Do not include any explanations or additional text; only list the learnings.
- Format each learning as a separate item in a list.

**Learnings that {user_name} already has stored (DO NOT REPEAT ANY)**:
```
{learnings_str}
```

**Conversation transcript**:
```
{conversation}
```

{output_language_instruction}
{format_instructions}
    '''.replace(
    '    ', ''
).strip()

extract_learnings_prompt = ChatPromptTemplate.from_messages([extract_learnings_prompt_text])
