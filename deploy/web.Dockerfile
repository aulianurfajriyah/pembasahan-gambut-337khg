# Image web Next.js (repo LH-KHG). Disimpan di repo ini agar repo web tidak perlu diubah;
# dipakai docker-compose.web.yml dengan context ../web.
# ponytail: satu stage + `next start` (tanpa output standalone); pecah multi-stage bila ukuran image jadi masalah.
FROM node:22-slim
WORKDIR /app
RUN corepack enable
COPY . .
RUN pnpm install --frozen-lockfile
ARG NEXT_PUBLIC_OGC_API_URL
ARG NEXT_PUBLIC_BASEMAP_STYLE_URL
ARG ESTIMASI_BIAYA_PER_SEKAT
ENV NEXT_TELEMETRY_DISABLED=1
RUN pnpm build
ENV NODE_ENV=production PORT=3000
EXPOSE 3000
CMD ["pnpm", "start"]
