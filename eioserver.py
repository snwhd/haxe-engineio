#!/usr/bin/env python3
from aiohttp import web
import engineio


async def handle(request):
    return web.Response(text='asdf');


app = web.Application()
app.add_routes([
    web.get('/', handle),
])

eio = engineio.AsyncServer(async_mode='aiohttp', logger=True)
eio.attach(app);
web.run_app(app);
