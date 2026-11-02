#!/usr/bin/env python3
"""Exercise the real MCP executable against disposable data; no provider access."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/unifai-mcp").resolve()
    now = time.time() - 978307200  # Foundation's reference date.
    account_id, payment_id = str(uuid.uuid4()), str(uuid.uuid4())
    state = {
        "schemaVersion": 1, "displayCurrency": "USD", "repositories": [],
        "accounts": [{
            "id": account_id, "integrationID": "deepseek", "label": "Synthetic",
            "billingScope": "Synthetic", "mode": "live", "createdAt": now - 7200,
            "snapshot": {
                "balances": [{"amount": 13.43, "currency": "USD"}],
                "details": [], "reportedConsumption": [], "observedAt": now,
                "source": "https://example.invalid", "coverage": "Synthetic only",
            },
        }],
        "payments": [{
            "id": payment_id, "accountID": account_id, "description": "Synthetic top-up",
            "kind": "Credit top-up", "money": {"amount": 10, "currency": "USD"},
            "paidAt": now - 3600, "createdAt": now - 3600, "reference": "SYNTHETIC-1", "estimated": True,
        }],
        "subscriptions": [{
            "id": str(uuid.uuid4()), "accountID": account_id, "name": "Synthetic monthly plan",
            "price": {"amount": 20, "currency": "USD"}, "cadence": "Monthly",
            "nextRenewal": now + 86400, "createdAt": now - 7200,
        }],
    }
    with tempfile.TemporaryDirectory(prefix="unifai-mcp-check-") as directory:
        root = Path(directory)
        source = root / "state.json"
        source.write_text(json.dumps(state))
        initial = hashlib.sha256(source.read_bytes()).hexdigest()

        def exchange(messages):
            process = subprocess.run(
                [str(binary), "--data-directory", directory],
                input="".join(json.dumps(message) + "\n" for message in messages),
                text=True, capture_output=True, timeout=15, check=True,
            )
            assert not process.stderr, process.stderr
            replies = [json.loads(line) for line in process.stdout.splitlines()]
            return {reply["id"]: reply for reply in replies}

        discovery = exchange([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ])
        assert discovery[1]["result"]["serverInfo"]["version"] == "0.3.0"
        tools = discovery[2]["result"]["tools"]
        assert len(tools) == 13
        assert all(tool["annotations"]["readOnlyHint"] for tool in tools)
        requests, names = [], {}
        for index, tool in enumerate(tools, 10):
            name = tool["name"]
            names[name] = index
            arguments = {}
            if name == "get_account_details":
                arguments["account_id"] = account_id
            if name == "get_payment":
                arguments["payment_id"] = payment_id
            requests.append({"jsonrpc": "2.0", "id": index, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
        requests += [
            {"jsonrpc": "2.0", "id": 90, "method": "tools/call", "params": {"name": "get_spending_breakdown", "arguments": {"limit": True}}},
            {"jsonrpc": "2.0", "id": 91, "method": "tools/call", "params": {"name": "delete_payment", "arguments": {}}},
        ]
        replies = exchange(requests)
        for name, index in names.items():
            result = replies[index]["result"]
            assert result["isError"] is False, (name, result)
            assert "structuredContent" in result
        breakdown = replies[names["get_spending_breakdown"]]["result"]["structuredContent"]["breakdown"]
        assert breakdown["total"]["amount"] == 10
        assert breakdown["estimatedPayments"]["amount"] == 10
        assert replies[names["get_payment"]]["result"]["structuredContent"]["status"] == "estimate"
        assert replies[names["get_unconfirmed_payments"]]["result"]["structuredContent"]["totalEntries"] == 1
        assert replies[90]["result"]["isError"] is True
        assert replies[91]["error"]["code"] == -32602
        assert hashlib.sha256(source.read_bytes()).hexdigest() == initial
        assert sorted(path.name for path in root.iterdir()) == ["state.json"]

        source.write_text("corrupt synthetic state")
        failure = exchange([requests[0]])
        assert failure[requests[0]["id"]]["result"]["isError"] is True
        assert source.read_text() == "corrupt synthetic state"
        assert sorted(path.name for path in root.iterdir()) == ["state.json"]
    print("PASS: 13 tools over stdio; structured results, argument errors, corrupt-state refusal, and unchanged data.")


if __name__ == "__main__":
    main()
