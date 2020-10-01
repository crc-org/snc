OC=${OC:-oc}

${OC} delete MutatingWebhookConfiguration/mutateme svc/mutateme deploy/mutateme
