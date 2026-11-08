defmodule SynapsisServer.DiffsControllerFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.DiffsDelivery
  alias Synapsis.Diffs.{Config, PortSession, Request}

  @moduletag timeout: 120_000
  @max_bytes 32 * 1024 * 1024

  test "actual viewer routes hydrate all controls and deliver complete PNG/PDF GET and HEAD bodies" do
    root =
      Path.join(
        System.tmp_dir!(),
        "synapsis-diffs-http-#{System.fetch_env!("MIX_TEST_PARTITION")}-#{Ecto.UUID.generate()}"
      )

    staging = Path.join(root, "staging")
    File.mkdir_p!(staging)
    on_exit(fn -> File.rm_rf!(root) end)

    listener =
      start_supervised!(
        {Gaoxy.HTTP,
         id: __MODULE__,
         plug: {SynapsisServer.Endpoint, []},
         ip: {127, 0, 0, 1},
         port: 0,
         http_limits: %{request_timeout: 30_000}}
      )

    %{local: {:ok, {_, port}}} = Gaoxy.info(listener, __MODULE__)
    assert {:ok, config} = Config.resolve(%{})

    binding = %{
      session_id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      invocation: %{
        run_id: Ecto.UUID.generate(),
        invocation_id: Ecto.UUID.generate(),
        tool_call_id: "ordinary-diffs-http",
        tool_name: "synapsis::diffs"
      }
    }

    opts = [
      root: Path.join(root, "artifacts"),
      staging_root: staging,
      max_bytes: @max_bytes,
      deadline: System.monotonic_time(:millisecond) + 90_000
    ]

    assert {:ok, renderer} =
             PortSession.start_link(
               owner_pid: self(),
               node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
               chromium_executable: System.fetch_env!("SYNAPSIS_DIFFS_CHROMIUM"),
               helper_path: Path.join(System.fetch_env!("SYNAPSIS_DIFFS_CAPSULE"), "stdio.mjs"),
               staging_root: staging
             )

    try do
      for format <- ~w(png pdf) do
        assert {:ok, plan} =
                 Request.prepare(
                   %{
                     "before" => "const value = 1;\n",
                     "after" => "const value = 2;\n",
                     "path" => "src/value.ts",
                     "title" => "Value update",
                     "mode" => "both",
                     "fileFormat" => format
                   },
                   %{"defaults" => config["defaults"], "languagePackAvailable" => false}
                 )

        assert {:ok, rendered} = PortSession.render(renderer, plan, 30_000)
        assert {:ok, viewer} = DiffsDelivery.publish_viewer(rendered, plan, binding, opts)
        assert {:ok, reserved} = DiffsDelivery.reserve_file(plan, binding, opts)

        assert {:ok, file} =
                 DiffsDelivery.complete_file(reserved, rendered["artifacts"]["file"], opts)

        assert {:ok, file_url} = DiffsDelivery.file_url(file.reference)
        script = Path.join(root, "observe-#{format}.mjs")
        report = Path.join(root, "observe-#{format}.json")
        File.write!(script, observer())

        assert {:ok, %{bytes: html}} =
                 DiffsDelivery.read_viewer(viewer.record.public_id, viewer.token, opts)

        assert {:ok, %{bytes: bytes}} =
                 DiffsDelivery.read_file(binding.session_id, file.reference["id"], opts)

        args = [
          script,
          System.fetch_env!("SYNAPSIS_DIFFS_CAPSULE"),
          System.fetch_env!("SYNAPSIS_DIFFS_CHROMIUM"),
          "http://127.0.0.1:#{port}",
          viewer.viewer_path,
          file_url,
          format,
          report,
          System.fetch_env!("SYNAPSIS_DIFFS_PDF_HELPER")
        ]

        assert run_node(args) == :ok
        observation = report |> File.read!() |> Jason.decode!()
        assert observation["viewerSha256"] == sha256(html)
        assert observation["fileSha256"] == sha256(bytes)
        assert observation["controls"] == ~w(layout wrap background theme)
        assert observation["assets"] == ~w(viewer.js viewer-runtime.js)
        assert observation["normalBrowserExit"] == true
        assert observation["prefixedHydration"] == true

        if evidence = System.get_env("SYNAPSIS_DIFFS_UI_EVIDENCE") do
          File.cp!(report, Path.join(evidence, "http-observer-#{format}.json"))
        end

        if format == "png" do
          assert observation["image"]["width"] == 2000
          assert observation["image"]["height"] == 640
          assert observation["image"]["painted"] == true
        else
          assert observation["pdfPages"] == 1
          extracted = String.replace(observation["pdfText"], ~r/\s/u, "")
          assert extracted =~ "constvalue=1;"
          assert extracted =~ "constvalue=2;"
        end

        assert :ok = DiffsDelivery.remove_artifact(viewer.record, opts)
        assert :ok = DiffsDelivery.remove_artifact(file.record, opts)
      end

      assert {:ok, %{cleanup_confirmed: true, exit_status: 0}} = PortSession.close(renderer)
    after
      if Process.alive?(renderer) do
        PortSession.close(renderer)
        GenServer.stop(renderer)
      end
    end
  end

  defp run_node(args) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"))},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: Enum.map(args, &String.to_charlist/1)
        ]
      )

    collect_node(port, [])
  end

  defp collect_node(port, chunks) do
    receive do
      {^port, {:data, bytes}} ->
        collect_node(port, [bytes | chunks])

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, code}} ->
        flunk("viewer observer exit #{code}: #{IO.iodata_to_binary(Enum.reverse(chunks))}")
    after
      45_000 ->
        Port.close(port)
        flunk("viewer observer did not finish")
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp observer do
    ~S"""
    import assert from 'node:assert/strict';
    import {createHash} from 'node:crypto';
    import {writeFile} from 'node:fs/promises';
    import {spawn} from 'node:child_process';
    import http from 'node:http';
    import {pathToFileURL} from 'node:url';
    const [capsule, executablePath, origin, viewerPath, filePath, format, report, pdfHelper] = process.argv.slice(2);
    const {chromium} = await import(pathToFileURL(capsule+'/node_modules/playwright-core/index.mjs'));
    const sha = bytes => createHash('sha256').update(bytes).digest('hex');
    const server = await chromium.launchServer({executablePath,headless:true,timeout:15000});
    const child = server.process();
    const exited = new Promise(resolve => child.once('exit', (code,signal)=>resolve({code,signal})));
    const browser = await chromium.connect(server.wsEndpoint(),{timeout:15000});
    const result = {controls:[],assets:[]};
    try {
      const page=await browser.newPage();page.setDefaultTimeout(10000);
      const response=await page.goto(origin+viewerPath,{waitUntil:'networkidle',timeout:15000});
      assert.equal(response.status(),200);
      const html=await response.body();result.viewerSha256=sha(html);
      assert.equal(response.headers()['content-type'],'text/html; charset=utf-8');
      await page.waitForFunction(()=>document.querySelector('diffs-container')?.shadowRoot?.querySelector('pre[data-diff]:not([data-dehydrated])'));
      const state=()=>page.evaluate(()=>{const host=document.querySelector('diffs-container'),pre=host.shadowRoot.querySelector('pre[data-diff]');return {layout:pre.getAttribute('data-diff-type'),overflow:pre.getAttribute('data-overflow'),background:pre.hasAttribute('data-background'),scheme:getComputedStyle(host).colorScheme,rows:[...pre.querySelectorAll('[data-line]')].map(r=>r.textContent)}});
      const initial=await state();assert.ok(initial.rows.some(r=>r.includes('const value = 2;')));
      for (const [kind,label] of [['layout','Switch to split diff'],['wrap','Disable word wrap'],['background','Hide background highlights'],['theme','Switch to light theme']]) {
        await page.locator('diffs-container').first().getByRole('button',{name:label,exact:true}).click();
        const after=await state();
        if(kind==='layout')assert.equal(after.layout,'split');
        if(kind==='wrap')assert.equal(after.overflow,'scroll');
        if(kind==='background')assert.equal(after.background,false);
        if(kind==='theme')assert.equal(after.scheme,'light');
        result.controls.push(kind);
      }
      const assets=await page.evaluate(()=>performance.getEntriesByType('resource').map(r=>new URL(r.name).pathname));
      for(const asset of ['viewer.js','viewer-runtime.js']) {
        assert.ok(assets.includes('/plugins/diffs/assets/'+asset));result.assets.push(asset);
        const r=await page.request.get(origin+'/plugins/diffs/assets/'+asset);assert.equal(r.status(),200);
      }
      const prefix='/synapsis-prefix';
      const proxy=http.createServer((request,response)=>{
        const upstream=http.request(new URL(request.url.slice(prefix.length),origin),{method:request.method,headers:request.headers},incoming=>{
          response.writeHead(incoming.statusCode,incoming.headers);incoming.pipe(response);
        });request.pipe(upstream);
      });
      await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
      const prefixed=await browser.newPage();
      try {
        const reply=await prefixed.goto('http://127.0.0.1:'+proxy.address().port+prefix+viewerPath,{waitUntil:'networkidle',timeout:15000});
        assert.equal(reply.status(),200);assert.equal(sha(await reply.body()),result.viewerSha256);
        await prefixed.waitForFunction(()=>document.querySelector('diffs-container')?.shadowRoot?.querySelector('pre[data-diff]:not([data-dehydrated])'));
        await prefixed.locator('diffs-container').first().getByRole('button',{name:'Switch to split diff',exact:true}).click();
        assert.equal(await prefixed.evaluate(()=>document.querySelector('diffs-container').shadowRoot.querySelector('pre[data-diff]').getAttribute('data-diff-type')),'split');
        const paths=await prefixed.evaluate(()=>performance.getEntriesByType('resource').map(r=>new URL(r.name).pathname));
        for(const asset of ['viewer.js','viewer-runtime.js'])assert.ok(paths.includes(prefix+'/plugins/diffs/assets/'+asset));
        result.prefixedHydration=true;result.prefixedAssets=paths;
      } finally {await prefixed.close();await new Promise(resolve=>proxy.close(resolve));}
      const head=await page.request.head(origin+viewerPath);assert.equal(head.status(),200);assert.equal((await head.body()).length,0);assert.equal(Number(head.headers()['content-length']),html.length);
      const file=await page.request.get(origin+filePath);assert.equal(file.status(),200);
      const bytes=await file.body();result.fileSha256=sha(bytes);
      assert.equal(file.headers()['content-type'],format==='png'?'image/png':'application/pdf');
      assert.equal(file.headers()['content-disposition'],'attachment; filename="preview.'+format+'"');
      assert.equal(Number(file.headers()['content-length']),bytes.length);
      const fileHead=await page.request.head(origin+filePath);assert.equal(fileHead.status(),200);assert.equal((await fileHead.body()).length,0);assert.equal(Number(fileHead.headers()['content-length']),bytes.length);
      if(format==='png') {
        result.image=await page.evaluate(async path=>{const image=new Image();image.src=path;await image.decode();const canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);const pixels=ctx.getImageData(0,0,image.width,image.height).data;const colors=new Set();for(let i=0;i<pixels.length;i+=4)colors.add(pixels[i]+','+pixels[i+1]+','+pixels[i+2]);return {width:image.width,height:image.height,painted:colors.size>30}},filePath);
      } else {
        const pdf=spawn(process.execPath,[pdfHelper,'--port','--timeout-ms=15000'],{stdio:['pipe','pipe','pipe']});
        let out='',err='';pdf.stdout.on('data',b=>out+=b);pdf.stderr.on('data',b=>err+=b);
        const exit=new Promise(resolve=>pdf.once('close',code=>resolve(code)));
        pdf.stdin.write(JSON.stringify({pdfBase64:bytes.toString('base64'),minTextChars:1})+'\n');
        assert.equal(await exit,0,err);const decoded=JSON.parse(out);
        result.pdfPages=decoded.metadata.pages.total;result.pdfText=decoded.text;
      }
    } finally {await browser.close();await server.close();assert.deepEqual(await exited,{code:0,signal:null});result.normalBrowserExit=true;}
    await writeFile(report,JSON.stringify(result));
    """
  end
end
