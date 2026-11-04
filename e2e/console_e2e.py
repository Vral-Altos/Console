"""Console E2E on emulators with a real Mac worker (README, "End-to-end test"):
sign-in gate, Overview live data, a chat that streams and finishes, stopping a
turn, rename / pin, Projects and System, phone layout, both themes."""
import re, sys
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

    # 4. Stopping a long turn keeps what it wrote (or notes it stopped early).
    type_and_send(page, re.compile('Reply to Genie'), 'E2E: write a 900-word essay about lighthouses, in plain paragraphs.')
    stop = page.get_by_role('button', name='Stop', exact=True)
    expect(stop.last).to_be_visible(timeout=60000)
    expect(seen(page, re.compile('Writing|Thinking'))).to_be_visible(timeout=120000)
    page.wait_for_timeout(4000)
    page.screenshot(path=f'{OUT}/4-streaming.png')
    stop.last.click()
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

    # 7. Dark theme, then a phone.
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
