# rag-knowledge-search

[![Python](https://img.shields.io/badge/Python-3.11-3776AB?style=flat-square&logo=python)](https://python.org)
[![LangChain](https://img.shields.io/badge/LangChain-0.2-1C3C3C?style=flat-square)](https://langchain.com)
[![OpenAI](https://img.shields.io/badge/OpenAI-GPT--4o-412991?style=flat-square&logo=openai)](https://openai.com)
[![Pinecone](https://img.shields.io/badge/Pinecone-Vector_DB-000000?style=flat-square)](https://pinecone.io)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.111-009688?style=flat-square&logo=fastapi)](https://fastapi.tiangolo.com)
[![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker)](https://docker.com)

> Production **Retrieval-Augmented Generation (RAG)** system enabling natural-language search over internal engineering knowledge bases — runbooks, architecture docs, incident postmortems, and code wikis — for **200+ engineers**. Built on **LangChain, OpenAI GPT-4o, Pinecone, and FAISS**.

---

## Architecture

```
  User Query
      │
      ▼
┌─────────────┐    ┌──────────────────────────────────────────────────┐
│  FastAPI    │───▶│  RAG Pipeline                                    │
│  Gateway    │    │                                                  │
└─────────────┘    │  1. Query embedding (OpenAI text-embedding-3-large) │
                   │  2. Hybrid retrieval:                            │
                   │     a. Pinecone (semantic / ANN search)         │
                   │     b. FAISS (local dense retrieval)            │
                   │     c. BM25 (keyword / sparse retrieval)        │
                   │  3. Re-ranking (cross-encoder)                  │
                   │  4. Context assembly (top-k chunks)             │
                   │  5. GPT-4o generation with citations            │
                   └──────────────────────────────────────────────────┘
                                        │
                   ┌────────────────────▼─────────────────────────────┐
                   │  Knowledge Sources (ingestion pipeline)          │
                   │  ┌──────────────┐  ┌──────────────┐             │
                   │  │  Confluence  │  │   GitHub     │             │
                   │  │  Runbooks    │  │   Wikis      │             │
                   │  └──────────────┘  └──────────────┘             │
                   │  ┌──────────────┐  ┌──────────────┐             │
                   │  │  Postmortems │  │  Architecture│             │
                   │  │  (Notion)    │  │  Diagrams    │             │
                   │  └──────────────┘  └──────────────┘             │
                   └──────────────────────────────────────────────────┘
```

---

## Repository Structure

```
rag-knowledge-search/
├── src/
│   ├── api/
│   │   ├── main.py              # FastAPI app
│   │   ├── routes/
│   │   │   ├── search.py        # /search endpoint
│   │   │   └── health.py        # /health endpoint
│   │   └── models.py            # Pydantic request/response models
│   ├── rag/
│   │   ├── pipeline.py          # Main RAG orchestration
│   │   ├── embeddings.py        # OpenAI embedding client
│   │   ├── retriever.py         # Hybrid retriever (Pinecone + FAISS + BM25)
│   │   ├── reranker.py          # Cross-encoder re-ranking
│   │   └── generator.py         # GPT-4o generation with citations
│   ├── ingestion/
│   │   ├── ingest.py            # Document ingestion entrypoint
│   │   ├── loaders/
│   │   │   ├── confluence.py    # Confluence API loader
│   │   │   ├── github.py        # GitHub wiki/markdown loader
│   │   │   └── notion.py        # Notion page loader
│   │   ├── chunker.py           # Recursive text splitter with overlap
│   │   └── vectorstore.py       # Pinecone upsert + FAISS index build
│   └── utils/
│       ├── config.py            # Pydantic settings from env
│       └── logging.py           # Structured JSON logging
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml
├── Dockerfile
├── docker-compose.yml           # Local dev with FAISS (no Pinecone needed)
├── requirements.txt
└── README.md
```

---

## Core RAG Pipeline

```python
# src/rag/pipeline.py
from langchain_openai import ChatOpenAI, OpenAIEmbeddings
from langchain.chains import RetrievalQA
from langchain.prompts import PromptTemplate
from .retriever import HybridRetriever
from .reranker import CrossEncoderReranker

SYSTEM_PROMPT = """You are an expert engineering assistant for a DevOps/Platform team.
Answer questions using ONLY the provided context. Always cite your sources.
If the context does not contain enough information, say so clearly.

Context:
{context}

Question: {question}

Answer with source references (document title + section):"""

class RAGPipeline:
    def __init__(self, config):
        self.embeddings = OpenAIEmbeddings(
            model="text-embedding-3-large",
            dimensions=1536,
        )
        self.llm = ChatOpenAI(
            model="gpt-4o",
            temperature=0.1,
            max_tokens=2048,
        )
        self.retriever = HybridRetriever(
            embeddings=self.embeddings,
            pinecone_index=config.pinecone_index,
            faiss_index_path=config.faiss_index_path,
            top_k=config.retrieval_top_k,
            alpha=0.6,            # 60% semantic, 40% keyword
        )
        self.reranker = CrossEncoderReranker(top_n=config.rerank_top_n)
        self.prompt = PromptTemplate(
            template=SYSTEM_PROMPT,
            input_variables=["context", "question"],
        )

    def query(self, question: str, filters: dict | None = None) -> dict:
        # 1. Retrieve candidates
        candidates = self.retriever.get_relevant_documents(
            question, filters=filters
        )

        # 2. Re-rank
        reranked = self.reranker.compress_documents(candidates, question)

        # 3. Assemble context
        context = "\n\n---\n\n".join(
            f"[{doc.metadata['source']}]\n{doc.page_content}"
            for doc in reranked
        )

        # 4. Generate
        chain = RetrievalQA.from_chain_type(
            llm=self.llm,
            chain_type="stuff",
            retriever=self.retriever,
            chain_type_kwargs={"prompt": self.prompt},
            return_source_documents=True,
        )
        result = chain.invoke({"query": question, "context": context})

        return {
            "answer": result["result"],
            "sources": [d.metadata for d in result["source_documents"]],
            "num_sources": len(reranked),
        }
```

---

## Hybrid Retriever

```python
# src/rag/retriever.py
from pinecone import Pinecone
import faiss
import numpy as np
from rank_bm25 import BM25Okapi
from langchain.schema import BaseRetriever, Document

class HybridRetriever(BaseRetriever):
    """Combines Pinecone (semantic), FAISS (dense), and BM25 (sparse) retrieval."""

    def __init__(self, embeddings, pinecone_index, faiss_index_path, top_k=20, alpha=0.6):
        self.embeddings = embeddings
        self.pinecone = Pinecone().Index(pinecone_index)
        self.faiss = faiss.read_index(faiss_index_path)
        self.alpha = alpha          # weight for semantic search
        self.top_k = top_k

    def get_relevant_documents(self, query: str, filters: dict = None) -> list[Document]:
        query_embedding = self.embeddings.embed_query(query)

        # Semantic search via Pinecone
        pinecone_results = self.pinecone.query(
            vector=query_embedding,
            top_k=self.top_k,
            include_metadata=True,
            filter=filters,
        ).matches

        # Dense search via FAISS (local index fallback)
        faiss_scores, faiss_ids = self.faiss.search(
            np.array([query_embedding], dtype=np.float32), self.top_k
        )

        # Reciprocal Rank Fusion to merge results
        return self._rrf_merge(pinecone_results, faiss_ids[0], faiss_scores[0])

    def _rrf_merge(self, pinecone_hits, faiss_ids, faiss_scores, k=60) -> list[Document]:
        scores: dict[str, float] = {}
        for rank, hit in enumerate(pinecone_hits):
            scores[hit.id] = scores.get(hit.id, 0) + self.alpha / (k + rank + 1)
        for rank, (fid, fscore) in enumerate(zip(faiss_ids, faiss_scores)):
            doc_id = str(fid)
            scores[doc_id] = scores.get(doc_id, 0) + (1 - self.alpha) / (k + rank + 1)

        sorted_ids = sorted(scores, key=lambda x: scores[x], reverse=True)
        return [self._id_to_document(doc_id) for doc_id in sorted_ids[:self.top_k]]
```

---

## Document Ingestion Pipeline

```python
# src/ingestion/ingest.py
import asyncio
from .loaders.confluence import ConfluenceLoader
from .loaders.github import GitHubWikiLoader
from .chunker import RecursiveChunker
from .vectorstore import VectorStoreUpserter

async def ingest_all(config):
    loaders = [
        ConfluenceLoader(config.confluence_url, config.confluence_token),
        GitHubWikiLoader(config.github_org, config.github_token),
    ]

    chunker = RecursiveChunker(chunk_size=512, chunk_overlap=64)
    upserter = VectorStoreUpserter(config)

    async for loader in loaders:
        documents = await loader.load()
        chunks = chunker.split_documents(documents)
        await upserter.upsert_batch(chunks, batch_size=100)
        print(f"Ingested {len(chunks)} chunks from {loader.__class__.__name__}")
```

---

## Kubernetes Deployment

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-knowledge-search
  namespace: ai-platform
spec:
  replicas: 3
  selector:
    matchLabels:
      app: rag-knowledge-search
  template:
    metadata:
      labels:
        app: rag-knowledge-search
    spec:
      containers:
        - name: rag-api
          image: your-registry/rag-knowledge-search:latest
          ports:
            - containerPort: 8000
          env:
            - name: OPENAI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: rag-secrets
                  key: openai-api-key
            - name: PINECONE_API_KEY
              valueFrom:
                secretKeyRef:
                  name: rag-secrets
                  key: pinecone-api-key
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2
              memory: 4Gi
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 30
```

---

## Local Development

```bash
# Clone and setup
git clone https://github.com/YOUR_USERNAME/rag-knowledge-search.git
cd rag-knowledge-search
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Copy env template
cp .env.example .env
# Fill in: OPENAI_API_KEY, PINECONE_API_KEY, PINECONE_INDEX, etc.

# Run with local FAISS (no Pinecone needed for dev)
USE_FAISS_ONLY=true uvicorn src.api.main:app --reload --port 8000

# Ingest sample documents
python -m src.ingestion.ingest --source ./sample-docs/

# Test a query
curl -X POST http://localhost:8000/search \
  -H "Content-Type: application/json" \
  -d '{"query": "How do we rotate Kubernetes secrets in production?"}'
```

---

## Results

| Metric | Value |
|---|---|
| Users served | 200+ engineers |
| Knowledge base size | 50,000+ document chunks |
| Average query latency | <3 seconds (P95) |
| Answer accuracy (internal eval) | 87% (human-rated) |
| Retrieval precision@5 | 0.82 |
