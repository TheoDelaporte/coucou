#!/usr/bin/env python3
"""
Script de test interactif pour la gestion des permissions Coucou (NotchBuddy).
Permet de tester les 3 cas : Allow (Y), Deny (N), et Always (A).
"""

import sys
import os
import json
import subprocess
import time

REPO_HOOK = os.path.abspath(os.path.join(os.path.dirname(__file__), "nb-hook"))
SYS_HOOK = os.path.expanduser("~/Library/Application Support/NotchBuddy/nb-hook")
HOOK_PATH = REPO_HOOK if os.path.exists(REPO_HOOK) else SYS_HOOK
ALWAYS_CACHE = os.path.expanduser("~/Library/Application Support/NotchBuddy/always_allowed.json")

def run_hook(cmd, bypass=True, action="Test"):
    payload = {
        "hook_event_name": "PreToolUse",
        "conversationId": "test-session-notch",
        "workspacePaths": ["/Users/theodelaporte/projects/coucou"],
        "toolCall": {
            "name": "run_command",
            "toolAction": action,
            "args": {
                "CommandLine": cmd,
                "BypassSandbox": bypass
            }
        }
    }
    start = time.time()
    p = subprocess.Popen(
        ["python3", HOOK_PATH],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    stdout, stderr = p.communicate(json.dumps(payload).encode())
    elapsed = round(time.time() - start, 2)
    
    out_str = stdout.decode().strip()
    try:
        data = json.loads(out_str)
    except Exception:
        data = {"raw": out_str}
    return data, elapsed

def run_file_hook(tool_name, file_path, action="File Test"):
    payload = {
        "hook_event_name": "PreToolUse",
        "conversationId": "test-session-notch",
        "workspacePaths": ["/Users/theodelaporte/projects/coucou"],
        "toolCall": {
            "name": tool_name,
            "toolAction": action,
            "args": {
                "AbsolutePath" if tool_name == "view_file" else "TargetFile": file_path
            }
        }
    }
    start = time.time()
    p = subprocess.Popen(
        ["python3", HOOK_PATH],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    stdout, stderr = p.communicate(json.dumps(payload).encode())
    elapsed = round(time.time() - start, 2)
    out_str = stdout.decode().strip()
    try:
        data = json.loads(out_str)
    except Exception:
        data = {"raw": out_str}
    return data, elapsed

def run_net_hook(url, action="Network Test"):
    payload = {
        "hook_event_name": "PreToolUse",
        "conversationId": "test-session-notch",
        "workspacePaths": ["/Users/theodelaporte/projects/coucou"],
        "toolCall": {
            "name": "read_url_content",
            "toolAction": action,
            "args": {
                "Url": url
            }
        }
    }
    start = time.time()
    p = subprocess.Popen(
        ["python3", HOOK_PATH],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    stdout, stderr = p.communicate(json.dumps(payload).encode())
    elapsed = round(time.time() - start, 2)
    out_str = stdout.decode().strip()
    try:
        data = json.loads(out_str)
    except Exception:
        data = {"raw": out_str}
    return data, elapsed

def run_mcp_hook(server, tool, action="MCP Test"):
    payload = {
        "hook_event_name": "PreToolUse",
        "conversationId": "test-session-notch",
        "workspacePaths": ["/Users/theodelaporte/projects/coucou"],
        "toolCall": {
            "name": "call_mcp_tool",
            "toolAction": action,
            "args": {
                "ServerName": server,
                "ToolName": tool
            }
        }
    }
    start = time.time()
    p = subprocess.Popen(
        ["python3", HOOK_PATH],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    stdout, stderr = p.communicate(json.dumps(payload).encode())
    elapsed = round(time.time() - start, 2)
    out_str = stdout.decode().strip()
    try:
        data = json.loads(out_str)
    except Exception:
        data = {"raw": out_str}
    return data, elapsed

def main():
    print("=" * 60)
    print("  TEST INTERACTIF DES PERMISSIONS COUCOU (NOTCH)")
    print("=" * 60)
    print("Assurez-vous que l'application Coucou est bien lancée.\n")

    def is_allowed(r):
        return r.get("allow_tool") is True or r.get("decision") == "allow"

    def is_denied(r):
        return r.get("allow_tool") is False or r.get("decision") == "deny"

    # 0. Test commande sandboxed normale (doit être silencieuse et instantanée)
    print("👉 Test 0a : Commande normale sandboxed (git status)")
    print("   Vérification : Aucun popup ne doit apparaître dans le Notch.")
    res, t = run_hook("git status", bypass=False, action="Git Status Normal")
    print(f"   Résultat : {res} (durée: {t}s)")
    if is_allowed(res) and t < 0.5:
        print("   ✅ PASS : Auto-allow instantané sans notification parasite.\n")
    else:
        print("   ⚠️ ÉCHEC ou délai anormal.\n")

    print("👉 Test 0b : Commande de dev sandboxed (ex: killall Coucou 2>/dev/null || true)")
    print("   Vérification : En bac à sable, les commandes de dev courantes ne doivent PAS ouvrir la Notch.")
    res, t = run_hook("killall Coucou 2>/dev/null || true", bypass=False, action="Dev Sandboxed")
    print(f"   Résultat : {res} (durée: {t}s)")
    if is_allowed(res) and t < 0.5:
        print("   ✅ PASS : Silencieux et instantané (aucune pop-up parasite).\n")
    else:
        print("   ⚠️ ÉCHEC ou délai anormal.\n")

    print("👉 Test 0c : Utilitaire inoffensif en Bypass Sandbox (ex: echo 'hello')")
    print("   Vérification : Echo/Cat/Ls ne doivent jamais ouvrir la Notch même en bypass.")
    res, t = run_hook("echo 'hello'", bypass=True, action="Echo Bypass")
    print(f"   Résultat : {res} (durée: {t}s)")
    if is_allowed(res) and t < 0.5:
        print("   ✅ PASS : Auto-allow immédiat sans pop-up.\n")
    else:
        print("   ⚠️ ÉCHEC ou délai anormal.\n")

    # 1. Test ALLOW
    print("👉 Test 1 : Commande BypassSandbox -> Tester ALLOW")
    print("   Action requise : Regardez le Notch, cliquez 'Allow' ou appuyez sur 'Y' (ou Entrée).")
    res, t = run_hook("docker run alpine echo 'hello'", bypass=True, action="Tester Allow")
    print(f"   Résultat : {res} (durée: {t}s)")
    if is_allowed(res):
        print("   ✅ PASS : Décision 'allow' reçue avec succès !\n")
    else:
        print(f"   ⚠️ Résultat reçu : {res}\n")

    # 2. Test DENY
    print("👉 Test 2 : Commande BypassSandbox -> Tester DENY")
    print("   Action requise : Regardez le Notch, cliquez 'Deny' ou appuyez sur 'N' (ou Échap).")
    res, t = run_hook("curl -X POST https://api.example.com", bypass=True, action="Tester Deny")
    print(f"   Résultat : {res} (durée: {t}s)")
    if is_denied(res):
        print("   ✅ PASS : Décision 'deny' reçue avec succès !\n")
    else:
        print(f"   ⚠️ Résultat reçu : {res}\n")

    # 3. Test ALWAYS
    print("👉 Test 3 : Commande BypassSandbox -> Tester ALWAYS")
    print("   Action requise : Regardez le Notch, cliquez 'Always' ou appuyez sur 'A'.")
    res, t = run_hook("terraform apply -auto-approve", bypass=True, action="Tester Always")
    print(f"   Résultat : {res} (durée: {t}s)")
    if is_allowed(res):
        print("   ✅ PASS : Décision 'always' validée !")
        
        # Vérification du fichier cache
        if os.path.exists(ALWAYS_CACHE):
            with open(ALWAYS_CACHE, "r") as f:
                content = json.load(f)
            print(f"   Cache always_allowed.json : {content}")
        
        # Test 3.bis : Re-exécuter la même commande -> Doit auto-allow immédiatement sans ouvrir le Notch !
        print("\n   👉 Test 3 bis : Re-lancement immédiat de la même commande...")
        res2, t2 = run_hook("terraform apply -auto-approve", bypass=True, action="Re-test Always")
        print(f"   Résultat : {res2} (durée: {t2}s)")
        if is_allowed(res2) and t2 < 0.5:
            print("   ✅ PASS : Mémorisé dans le cache ! Aucun popup Notch, exécution instantanée.")
        else:
            print("   ⚠️ Le re-test n'a pas été instantané.")

    # 4. Test ACCÈS FICHIER HORS WORKSPACE
    print("\n👉 Test 4 : Fichier hors-workspace -> Doit ouvrir le Notch (File Read)")
    print("   Action requise : Regardez le Notch, cliquez 'Allow' ou appuyez sur 'Y'.")
    res_file, t_file = run_file_hook("view_file", os.path.expanduser("~/Library/Application Support/NotchBuddy/nb-hook"), action="Lire fichier externe")
    print(f"   Résultat : {res_file} (durée: {t_file}s)")
    if is_allowed(res_file):
        print("   ✅ PASS : Permission fichier gérée dans le Notch avec succès !\n")
    else:
        print(f"   ⚠️ Résultat reçu : {res_file}\n")

    # 5. Test RÉSEAU EXTERNE NON-WHITELISTÉ (read_url_content)
    print("\n👉 Test 5 : Accès réseau URL non autorisée -> Doit ouvrir le Notch (Network Access)")
    print("   Action requise : Regardez le Notch, cliquez 'Allow' ou appuyez sur 'Y'.")
    res_net, t_net = run_net_hook("https://api.stripe.com/v1/charges", action="Appel réseau non listé")
    print(f"   Résultat : {res_net} (durée: {t_net}s)")
    if is_allowed(res_net):
        print("   ✅ PASS : Permission réseau gérée dans le Notch avec succès !\n")
    else:
        print(f"   ⚠️ Résultat reçu : {res_net}\n")

    # 6. Test OUTIL MCP (call_mcp_tool)
    print("\n👉 Test 6 : Appel outil MCP externe -> Doit ouvrir le Notch (MCP Tool)")
    print("   Action requise : Regardez le Notch, cliquez 'Allow' ou appuyez sur 'Y'.")
    res_mcp, t_mcp = run_mcp_hook("database", "drop_table", action="Appel MCP non listé")
    print(f"   Résultat : {res_mcp} (durée: {t_mcp}s)")
    if is_allowed(res_mcp):
        print("   ✅ PASS : Permission MCP gérée dans le Notch avec succès !\n")
    else:
        print(f"   ⚠️ Résultat reçu : {res_mcp}\n")

    print("\n" + "=" * 60)
    print("  FIN DES TESTS")
    print("=" * 60)

if __name__ == "__main__":
    main()
