# Git Workflow & Pair Programming Rules

Pour l'ensemble de nos sessions de dev sur ce projet, applique strictement les règles de workflow Git suivantes :

## 1. Format des commits (Pair Programming)
- Ne committe **jamais** sans co-auteur.
- À la fin de chaque message de commit, laisse une ligne vide et ajoute obligatoirement le trailer suivant :
  ```text
  Co-authored-by: Antigravity <agent@antigravity.google.com>
  ```
- Exemple de commande :
  ```bash
  git commit -m "feat(auth): add jwt middleware" -m "Co-authored-by: Antigravity <agent@antigravity.google.com>"
  ```

## 2. Cycle de livraison par PR (GitHub Flow)
- Ne pousse **jamais** directement sur la branche principale (`main` ou `master`).
- Pour chaque tâche, bugfix ou feature :
  1. Crée une branche dédiée : `git checkout -b <type>/<nom-court>`
  2. Fais tes commits selon la règle 1 (avec le trailer Co-authored-by).
  3. Pousse la branche et ouvre immédiatement une Pull Request via le CLI : `gh pr create --fill`
  4. Une fois les tests validés, merge la PR directement sans attendre de revue : `gh pr merge --squash --delete-branch`

## 3. Hotfixes & Tâches rapides
- Pour les correctifs rapides (< 5 min), ouvre d'abord une issue : `gh issue create --title "..." --body "..."`
- Lie-la à ta PR ou ton commit (`Closes #ID`) pour qu'elle soit clôturée immédiatement lors du merge.

## 4. Intégrité
- Tout ce workflow doit s'appliquer uniquement à du vrai code utile pour le projet (pas de faux commits ni de PRs vides). La qualité du code, la sécurité et les tests restent prioritaires.
