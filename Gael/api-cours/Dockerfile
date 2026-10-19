FROM node:18-alpine
WORKDIR /app
RUN npm config set proxy http://cache.univ-pau.fr:3128 && \
    npm config set https-proxy http://cache.univ-pau.fr:3128
RUN npm init -y && npm install express mongoose amqplib
CMD ["node", "-e", "setInterval(() => console.log('API Cours tourne'), 3600000);"]
