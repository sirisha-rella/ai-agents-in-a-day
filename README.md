# AI Agents in a Day

Hands-on labs for running Nemotron, Hermes Agent, and OpenShell on a DGX Spark / Dell Pro Max GB10.

You run a Nemotron model on your own machine and connect Hermes Agent to it. Then you use OpenShell to call the model from inside a sandbox, and see a request to any other host denied. Everything runs on the GB10 in front of you.

| Notebook | What you do |
|---|---|
| [`nemotron_deploy_part1.ipynb`](notebooks/nemotron_deploy_part1.ipynb) | Download Nemotron 3 Nano (FP8), serve it with vLLM in Docker, send requests, and measure speed, memory and long-context behavior |
| [`connect_hermes_agent_to_nemotron_part2.ipynb`](notebooks/connect_hermes_agent_to_nemotron_part2.ipynb) | Restart the server with a larger context window, install Hermes Agent, and point it at your model |
| [`connect_openshell_to_nemotron_part3.ipynb`](notebooks/connect_openshell_to_nemotron_part3.ipynb) | Install OpenShell, create a provider, and see a sandbox reach your model server while a request to another host is denied |

## 1. Get the code and download everything

Do this before the workshop. It downloads everything the labs need and can be left running. Run it on your Dell Pro Max GB10 or DGX Spark (over SSH is fine). You need at least 100 GB of free disk.

Check that `git` is installed with `git --version`. If it is not, install it first:

```bash
sudo apt-get install -y git
```

Then:

```bash
git clone https://github.com/sirisha-rella/ai-agents-in-a-day.git
cd ai-agents-in-a-day
sudo -v && nohup ./scripts/prefetch.sh > prefetch.log 2>&1 &
tail -f prefetch.log
```

`prefetch.sh` sets up, in order:

1. Docker with GPU access: it tests that a container can see the GPU, and installs or configures Docker only if that test fails
2. A Python environment with JupyterLab (in `~/nemotron-labs/.venv`)
3. The model weights: `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-FP8`, saved to `~/models/nemotron-3-nano-fp8` (about 33 GB)
4. The Docker images: `vllm/vllm-openai:v0.20.0`, `ubuntu:24.04` and `buildpack-deps:noble-curl`
5. Hermes Agent
6. OpenShell, pinned to `v0.1.4`

It retries failed downloads, keeps going if one step fails, and ends with an `[OK]` / `[FAIL]` summary and a check that everything is in place. If anything shows `[FAIL]`, run the script again: finished downloads are skipped. Press Ctrl-C to stop watching the log; the script keeps running.

## 2. Open the notebooks

When the script finishes it prints the command to start JupyterLab. Run it on the Spark:

```bash
~/nemotron-labs/.venv/bin/jupyter lab --notebook-dir ~/ai-agents-in-a-day/notebooks --ip=127.0.0.1 --port=8888 --no-browser
```

Jupyter prints a URL with a token. To reach it from your own computer, open an SSH tunnel from your computer:

```bash
ssh -L 8888:localhost:8888 <user>@<spark-ip>
```

Then open `http://localhost:8888/lab?token=<token>` in your browser.

### If you connect directly instead

Start Jupyter with `--ip=0.0.0.0` and open it by **IP address**. Jupyter prints the Spark's hostname in its URL (for example `http://spark-14b8:8888/...`), and your computer usually cannot resolve that name, so the browser says "site can't be reached". Replace the hostname with the Spark's IP address:

```bash
hostname -I        # run on the Spark; the first address is usually the one you want
```

```
http://<spark-ip>:8888/lab?token=<token>
```

`--ip=0.0.0.0` lets anyone on the network who has the token run code on the Spark. Use it only on a network you trust, and stop Jupyter when you are done.

To list the running Jupyter servers and their tokens: `~/nemotron-labs/.venv/bin/jupyter server list`. It can list stale entries from servers that have stopped. The live one is the one with a process listening on its port (`ss -ltnp | grep 8888`).

## 3. Run the labs

Open each notebook and choose **Kernel > Restart Kernel and Run All**, or run the cells one at a time.

1. **Part 1.** Loading the model takes about 4 to 5 minutes. Part 1 ends by stopping the model server to free memory.
2. **Part 2.** Starts the server again with a 65,536-token context window (Hermes needs at least 64,000), installs Hermes, and runs it against your model. It leaves the server running.
3. **Part 3.** Needs the server from Part 2 to be running. It installs OpenShell and shows the allow and deny behavior. The cell in section 3 first deletes any sandbox, provider and profile left from an earlier run, so Part 3 is safe to run again.

The model server reserves most of the unified memory while it runs (about 80%), which is why Part 1 stops it before Part 2 starts it again with a larger context window.

If the model is already downloaded, Part 1's download cell finds the files and finishes quickly.

## Versions these notebooks were verified on

- Model: Nemotron 3 Nano 30B-A3B, FP8
- vLLM image: `v0.20.0`
- Hermes Agent: v0.22.2
- OpenShell: 0.1.4 (pinned in `prefetch.sh` and in Part 3's install cell; 0.1.5 has not been tested with Part 3)
- Hardware: Dell Pro Max GB10 / DGX Spark, Ubuntu 24.04

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Browser says "site can't be reached" | Jupyter is not running (`ss -ltnp \| grep 8888`), or you used the hostname instead of the IP address. See [Open the notebooks](#2-open-the-notebooks). |
| The model server runs out of memory at start | Lower `--gpu-memory-utilization` to `0.70`, then lower `--max-model-len`, and run the cell again. |
| Hermes prints a tool call as text instead of running it | Seen occasionally in testing. Run the cell again. |
| `prefetch.sh` shows `[FAIL]` | Run it again. Finished downloads are skipped. |
| `docker` permission errors | Your user must be in the `docker` group. If `prefetch.sh` added you to it, log out and back in (or reboot) before running the notebooks. |
| Part 3 can't reach the model | Check that the server from Part 2 is still running: `docker ps` should list `vllm-nemotron-nano`. |

## Stop everything

```bash
docker rm -f vllm-nemotron-nano     # stop the model server (the model files stay on disk)
pkill -f jupyter-lab                # stop Jupyter
```
