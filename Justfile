release version:
		docker build . -t harbor.k8s.inpt.fr/net7_public/churros-git-bot:{{ version }}
		docker tag harbor.k8s.inpt.fr/net7_public/churros-git-bot:{{ version }} harbor.k8s.inpt.fr/net7_public/churros-git-bot:latest
		docker push harbor.k8s.inpt.fr/net7_public/churros-git-bot:{{ version }}
		docker push harbor.k8s.inpt.fr/net7_public/churros-git-bot:latest
		git tag v{{ version }}
		git push --tags
