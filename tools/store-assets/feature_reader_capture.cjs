const { chromium } = require(process.env.PLEZY_PLAYWRIGHT_PATH || '../reader-tests/node_modules/playwright');
const path = require('path');
(async () => {
  const browser = await chromium.launch({executablePath:process.env.PLEZY_CHROME_PATH || '/usr/bin/chromium',headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
  try {
    const page = await browser.newPage({viewport:{width:1280,height:800},deviceScaleFactor:1.5});
    const errors=[]; page.on('pageerror', e=>errors.push(e.message));
    await page.goto(process.argv[2]);
    await page.waitForFunction(()=>document.title.includes('The Night Library'));
    await page.waitForFunction(()=>document.querySelector('foliate-view')?.lastLocation?.cfi);
    await page.evaluate(()=>window.publication.settings(window.readerOptions.settings));
    await page.waitForFunction(()=>{const doc=document.querySelector('foliate-view')?.renderer?.getContents?.()[0]?.doc;return doc && doc.defaultView.getComputedStyle(doc.body).color !== 'rgb(0, 0, 0)'});
    await page.evaluate(()=>document.fonts.ready);
    const labels=await page.evaluate(()=>window.readerOptions.labels);
    await page.screenshot({path:path.join(process.argv[3],'ebook-reader-dark.png')});
    await page.getByRole('button',{name:labels.settings,exact:true}).click();
    await page.screenshot({path:path.join(process.argv[3],'ebook-reading-settings-dark.png')});
    await page.getByRole('button',{name:labels.close,exact:true}).click();
    await page.setViewportSize({width:390,height:844});
    await page.waitForTimeout(300);
    await page.screenshot({path:path.join(process.argv[3],'ebook-reader-phone-dark.png')});
    await page.setViewportSize({width:520,height:360});
    await page.waitForTimeout(300);
    await page.screenshot({path:path.join(process.argv[3],'ebook-workspace-surface-dark.png')});
    if(errors.length)throw Error(errors.join('\n'));
    console.log(JSON.stringify({captures:4,engine:'production PublicationServer / foliate',errors:0}));
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
