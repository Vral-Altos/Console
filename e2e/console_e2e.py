"""Console E2E on emulators with a real Mac worker (README, "End-to-end test"):
sign-in gate, Overview live data, a chat that streams and finishes, tool use
folded to a line and highlighted code, stopping a turn with Esc, rename / pin, attachments (picked and dropped) and @mentions read by
the agent, Projects and System, phone layout, both themes."""
import re, struct, sys, zlib
from playwright.sync_api import sync_playwright, expect

URL = 'http://localhost:5055/'
OUT = sys.argv[1]

def enable_semantics(page):
    page.wait_for_selector('flt-semantics-placeholder', state='attached', timeout=30000)
    page.evaluate("document.querySelector('flt-semantics-placeholder').click()")
    page.wait_for_timeout(500)

def sign_in(page, email):
    with page.expect_popup() as pop:
        page.get_by_role('button', name=re.compile('Sign in with Google')).click()
    p = pop.value
    p.wait_for_load_state()
    p.get_by_text('Add new account').click()
    p.locator('#email-input').fill(email)
    p.locator('#display-name-input').fill('Operator')
    p.locator('#sign-in').click()

def seen(page, pattern):
    """Text on screen. Flutter merges a card's texts into one accessible
    label, so this matches visible text or any element's aria-label."""
    rx = pattern if isinstance(pattern, re.Pattern) else re.compile(re.escape(pattern))
    return page.get_by_text(rx).or_(page.get_by_label(rx)).first

def tab(page, name):
    page.get_by_role('button', name=re.compile(f'^{name} Tab')).click()
    page.wait_for_timeout(700)

def type_and_send(page, box_name, text):
    box = page.get_by_role('textbox', name=box_name)
    box.click()
    page.wait_for_timeout(400)
    page.keyboard.type(text)
    expect(box).to_have_value(text)
    page.keyboard.press('Enter')  # Enter sends

def red_png(path, w=48, h=32):
    """A plain red image, for the agent to name its colour."""
    row = b'\x00' + b'\xd0\x10\x10' * w
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(row * h)) + chunk(b'IEND', b'')
    open(path, 'wb').write(data)

DROP_JS = """([name, text]) => {
  const dt = new DataTransfer();
  dt.items.add(new File([text], name, {type: 'text/plain'}));
  for (const type of ['dragenter', 'dragover', 'drop']) {
    window.dispatchEvent(new DragEvent(type, {dataTransfer: dt, bubbles: true, cancelable: true}));
  }
}"""

with sync_playwright() as pw:
    b = pw.chromium.launch()
    ctx = b.new_context(viewport={'width': 1440, 'height': 900})
    page = ctx.new_page()
    errors = []
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)

    # 1. A stranger is refused.
    page.goto(URL); enable_semantics(page)
    sign_in(page, 'obsidian.infinitum@gmail.com')
    expect(seen(page, 'Not authorised')).to_be_visible(timeout=20000)
    page.get_by_role('button', name='Sign out').click()
    print('stranger refused: ok')

    # 2. The operator gets in; the Overview shows the live Mac worker.
    sign_in(page, 'siddharth.chitikela@gmail.com')
    expect(page.get_by_role('button', name=re.compile('^Overview Tab'))).to_be_visible(timeout=30000)
    page.add_style_tag(content='.firebase-emulator-warning{display:none!important}')
    expect(seen(page, 'Mac worker')).to_be_visible(timeout=20000)
    expect(seen(page, 'Serving')).to_be_visible(timeout=90000)
    expect(seen(page, 'Live now')).to_be_visible()
    page.screenshot(path=f'{OUT}/1-overview.png')
    print('overview: ok')

    # 3. A new chat with Genie streams and finishes.
    tab(page, 'Chat')
    page.get_by_role('button', name='New chat').click()
    page.get_by_role('button', name=re.compile('Agent Genie')).click()
    type_and_send(page, re.compile('Message Genie'), 'E2E: write exactly three numbered sentences about the sea, nothing else.')
    expect(seen(page, re.compile('Waiting for the Mac|Thinking|Writing'))).to_be_visible(timeout=30000)
    page.screenshot(path=f'{OUT}/2-pending.png')
    expect(seen(page, re.compile(r'(PM|AM|\d) · Mac · '))).to_be_visible(timeout=240000)
    page.screenshot(path=f'{OUT}/3-reply.png')
    print('chat reply: ok')

    # 3b. Tool use folds to one line that opens; code arrives highlighted.
    type_and_send(page, re.compile('Reply to Genie'),
                  'E2E: use the Read tool once to read your CLAUDE.md, then reply with only a 3-line Python code block '
                  'that prints the numbers 1 to 3. No other text.')
    used = seen(page, re.compile(r'^Used (Read|\d+ tools)'))
    expect(used).to_be_visible(timeout=240000)
    expect(page.get_by_role('button', name=re.compile('^Copy$')).first).to_be_visible()
    page.wait_for_timeout(800)
    page.screenshot(path=f'{OUT}/3b-code.png')
    used.click()
    expect(seen(page, re.compile(r'^Read( ×\d+)?$'))).to_be_visible(timeout=5000)
    page.screenshot(path=f'{OUT}/3c-tools-open.png')
    print('tools and code: ok')

    # 4. Stopping a long turn keeps what it wrote (or notes it stopped early).
    type_and_send(page, re.compile('Reply to Genie'), 'E2E: write a 900-word essay about lighthouses, in plain paragraphs.')
    stop = page.get_by_role('button', name='Stop', exact=True)
    expect(stop.last).to_be_visible(timeout=60000)
    expect(seen(page, re.compile('Writing|Thinking'))).to_be_visible(timeout=120000)
    page.wait_for_timeout(4000)
    page.screenshot(path=f'{OUT}/4-streaming.png')
    # Esc in the message box stops the turn.
    page.get_by_role('textbox', name=re.compile('Reply to Genie')).click()
    page.keyboard.press('Escape')
    expect(seen(page, re.compile('Stopped'))).to_be_visible(timeout=60000)
    page.screenshot(path=f'{OUT}/5-stopped.png')
    print('stop: ok')

    # 5. Rename and pin through the conversation menu.
    page.get_by_role('button', name='Conversation options').last.click()
    page.get_by_role('menuitem', name=re.compile('Rename')).click()
    box = page.get_by_role('textbox', name='Title')
    box.click(); page.keyboard.press('ControlOrMeta+a'); page.keyboard.type('E2E sea essays')
    page.get_by_role('button', name='Rename', exact=True).click()
    expect(seen(page, 'E2E sea essays')).to_be_visible(timeout=20000)
    page.get_by_role('button', name='Conversation options').last.click()
    page.get_by_role('menuitem', name=re.compile('^Pin')).click()
    expect(seen(page, re.compile('^Pinned$'))).to_be_visible(timeout=20000)
    page.screenshot(path=f'{OUT}/6-renamed-pinned.png')
    print('rename and pin: ok')

    # 5b. Files and @mentions: a picked image and text file, a dropped file
    # (removed again), and a mention of an earlier conversation; the agent
    # reads all of them.
    red_png(f'{OUT}/swatch.png')
    open(f'{OUT}/note.txt', 'w').write('The secret word is MARMALADE.\n')
    page.get_by_role('button', name='New chat').click()
    page.get_by_role('button', name=re.compile('Agent Genie')).click()
    type_and_send(page, re.compile('Message Genie'),
                  'E2E memo thread, nothing important here at all, just a filler line. Codeword: PELICAN. Reply OK.')
    # This conversation's own reply (the previous one may still be fading out).
    expect(seen(page, re.compile(r'Genie\s+OK'))).to_be_visible(timeout=240000)
    page.get_by_role('button', name='New chat').click()
    page.get_by_role('button', name=re.compile('Agent Genie')).click()
    with page.expect_file_chooser() as fc:
        page.get_by_role('button', name='Attach files').click()
    fc.value.set_files([f'{OUT}/swatch.png', f'{OUT}/note.txt'])
    expect(seen(page, 'Attachment swatch.png')).to_be_visible(timeout=20000)
    expect(seen(page, 'Attachment note.txt')).to_be_visible()
    page.evaluate(DROP_JS, ['dropped.txt', 'dropped'])
    expect(seen(page, 'Attachment dropped.txt')).to_be_visible(timeout=20000)
    page.wait_for_timeout(1500)  # uploads finish
    page.get_by_role('button', name='Remove dropped.txt').click()
    expect(seen(page, 'Attachment dropped.txt')).to_have_count(0)
    box = page.get_by_role('textbox', name=re.compile('Message Genie'))
    box.click(); page.wait_for_timeout(300)
    page.keyboard.type('In @memo')
    expect(page.get_by_role('button', name=re.compile('^Mention E2E memo thread')).first).to_be_visible(timeout=10000)
    page.screenshot(path=f'{OUT}/6a-mention-menu.png')
    page.keyboard.press('Enter')  # picks the highlighted conversation
    page.keyboard.type('what was the codeword? Also: the secret word in note.txt, and the colour of the image. '
                       'Reply exactly as: codeword, word, colour.')
    page.screenshot(path=f'{OUT}/6b-composer-files.png')
    page.keyboard.press('Enter')
    expect(page.get_by_role('button', name='Image swatch.png')).to_be_visible(timeout=30000)
    expect(page.get_by_role('button', name=re.compile('^Attachment note.txt'))).to_be_visible()
    # The reply names all three: the mentioned conversation's codeword, the
    # text file's word and the image's colour.
    expect(seen(page, re.compile(r'PELICAN.*MARMALADE.*\bred\b', re.I | re.S))).to_be_visible(timeout=240000)
    page.screenshot(path=f'{OUT}/6c-files-answered.png')
    print('attachments and mentions: ok')

    # 6. The turns are counted; Projects and System render live data.
    tab(page, 'Overview')
    expect(seen(page, 'Chat turns today')).to_be_visible()
    page.screenshot(path=f'{OUT}/7-overview-after.png', full_page=True)
    tab(page, 'Projects')
    expect(page.get_by_role('button', name='New Devstation')).to_be_visible()
    page.screenshot(path=f'{OUT}/8-projects.png')
    tab(page, 'System')
    expect(seen(page, 'Agent sessions')).to_be_visible()
    expect(seen(page, 'Where chats ran')).to_be_visible()
    page.screenshot(path=f'{OUT}/9-system.png')
    print('projects and system: ok')

    # 7. The Logs page: the worker's entries, metrics and the audit trail.
    tab(page, 'Logs')
    expect(seen(page, re.compile('Turn done with genie'))).to_be_visible(timeout=60000)
    expect(seen(page, re.compile('Turn stopped by the operator'))).to_be_visible(timeout=30000)
    page.screenshot(path=f'{OUT}/9a-logs.png')
    page.get_by_role('tab', name=re.compile('Monitoring')).click()
    page.wait_for_timeout(1500)
    expect(seen(page, 'Turn latency')).to_be_visible(timeout=20000)
    page.screenshot(path=f'{OUT}/9b-monitoring.png')
    page.get_by_role('tab', name=re.compile('Activity')).click()
    expect(seen(page, re.compile('Started a conversation with genie'))).to_be_visible(timeout=30000)
    expect(seen(page, re.compile('Worker started'))).to_be_visible(timeout=30000)
    page.screenshot(path=f'{OUT}/9c-activity.png')
    print('logs, monitoring and activity: ok')

    # 8. Dark theme, then a phone.
    page.get_by_role('button', name='Dark theme').click()
    tab(page, 'Chat')
    page.screenshot(path=f'{OUT}/10-dark.png')
    page.set_viewport_size({'width': 390, 'height': 844})
    page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/11-phone-chat.png')
    page.get_by_role('button', name='Conversations').first.click()
    expect(page.get_by_role('button', name='New chat')).to_be_visible()
    page.screenshot(path=f'{OUT}/12-phone-drawer.png')
    page.keyboard.press('Escape'); page.wait_for_timeout(600)
    page.get_by_role('tab', name=re.compile('Overview')).click()
    page.wait_for_timeout(1200)
    page.screenshot(path=f'{OUT}/13-phone-overview.png')
    print('phone and dark: ok')

    bad = [e for e in errors if 'favicon' not in e]
    print('console errors:', bad[:8])
    b.close()
