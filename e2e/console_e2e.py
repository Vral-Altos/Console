"""Console E2E on emulators: sign-in gate, chat through the real Mac worker, Maintenance, Factory, close."""
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

with sync_playwright() as pw:
    b = pw.chromium.launch()
    ctx = b.new_context(viewport={'width': 1280, 'height': 800})
    page = ctx.new_page()
    errors = []
    page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)

    # 1. A stranger is refused.
    page.goto(URL); enable_semantics(page)
    sign_in(page, 'stranger@example.com')
    expect(page.get_by_text('Not authorised')).to_be_visible(timeout=20000)
    page.screenshot(path=f'{OUT}/1-stranger.png')
    page.get_by_role('button', name='Sign out').click()
    expect(page.get_by_role('button', name=re.compile('Sign in with Google'))).to_be_visible(timeout=20000)
    print('stranger refused: ok')

    # 2. The operator gets in and chats with Genie through the Mac worker.
    sign_in(page, 'obsidian.infinitum@gmail.com')
    expect(page.get_by_role('button', name='New conversation')).to_be_visible(timeout=20000)
    expect(page.get_by_role('checkbox', name='Mac')).to_be_visible(timeout=20000)
    box = page.get_by_role('textbox', name='Message genie')
    box.click()
    page.wait_for_timeout(800)
    page.keyboard.type('E2E check: reply with exactly the words console works')
    expect(box).to_have_value('E2E check: reply with exactly the words console works')
    page.get_by_role('button', name='Send').click()
    page.screenshot(path=f'{OUT}/2-sent.png')
    expect(page.get_by_role('textbox', name=re.compile('Answered on the mac'))).to_be_attached(timeout=180000)
    expect(page.get_by_role('button', name=re.compile(r'^G E2E check.*genie · .*console works', re.I)).first).to_be_visible()
    page.screenshot(path=f'{OUT}/3-reply.png')
    print('chat reply: ok')

    # 3. Maintenance and Factory show live state.
    page.get_by_role('button', name=re.compile('^Maintenance Tab')).click()
    expect(page.get_by_text(re.compile('Serving'))).to_be_visible(timeout=20000)
    expect(page.get_by_text(re.compile('genie · console-')).first).to_be_visible(timeout=20000)
    page.screenshot(path=f'{OUT}/4-maintenance.png')
    page.get_by_role('button', name=re.compile('^Factory Tab')).click()
    expect(page.get_by_text(re.compile('No Devstations'))).to_be_visible(timeout=20000)
    page.screenshot(path=f'{OUT}/5-factory.png')
    print('maintenance and factory: ok')

    # 4. Closing the conversation journals it and closes the thread.
    page.get_by_role('button', name=re.compile('^Chat Tab')).click()
    page.get_by_role('button', name='Close', exact=True).first.click()
    # A closed thread loses its composer and its Close button.
    expect(page.get_by_role('textbox', name='Message genie')).to_have_count(0, timeout=180000)
    expect(page.get_by_role('button', name='Close', exact=True)).to_have_count(0)
    page.screenshot(path=f'{OUT}/6-closed.png')
    print('close: ok')

    # 5. Narrow (phone) layout works.
    page.set_viewport_size({'width': 390, 'height': 800})
    page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/7a-phone-thread.png')
    expect(page.get_by_role('button', name='Conversations')).to_be_visible()
    page.get_by_role('button', name='Conversations').click()
    expect(page.get_by_role('button', name='New conversation')).to_be_visible()
    expect(page.get_by_role('tab', name=re.compile('Maintenance')).or_(page.get_by_role('button', name=re.compile('Maintenance'))).first).to_be_attached()
    page.screenshot(path=f'{OUT}/7-phone.png')
    print('phone layout: ok')
    bad = [e for e in errors if 'favicon' not in e]
    print('console errors:', bad[:5])
    b.close()
