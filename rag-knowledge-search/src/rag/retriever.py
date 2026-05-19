import os
import numpy as np
import faiss
from pinecone import Pinecone
from langchain.schema import BaseRetriever, Document
from rank_bm25 import BM25Okapi
from typing import List


class HybridRetriever(BaseRetriever):
    """Combines Pinecone (semantic), FAISS (dense), and BM25 (sparse) retrieval
    using Reciprocal Rank Fusion for result merging."""

    def __init__(self, embeddings, pinecone_index, faiss_index_path, top_k=20, alpha=0.6):
        self.embeddings = embeddings
        self.pc = Pinecone(api_key=os.environ["PINECONE_API_KEY"])
        self.index = self.pc.Index(pinecone_index)
        self.faiss_index = faiss.read_index(faiss_index_path)
        self.top_k = top_k
        self.alpha = alpha  # weight: 1.0 = fully semantic, 0.0 = fully keyword

    def get_relevant_documents(self, query: str, filters: dict = None) -> List[Document]:
        query_embedding = self.embeddings.embed_query(query)

        # Semantic search via Pinecone
        pinecone_results = self.index.query(
            vector=query_embedding,
            top_k=self.top_k,
            include_metadata=True,
            filter=filters,
        ).matches

        # Dense search via FAISS
        vec = np.array([query_embedding], dtype=np.float32)
        faiss_scores, faiss_ids = self.faiss_index.search(vec, self.top_k)

        return self._rrf_merge(pinecone_results, faiss_ids[0], faiss_scores[0])

    def _rrf_merge(self, pinecone_hits, faiss_ids, faiss_scores, k=60) -> List[Document]:
        scores: dict[str, float] = {}

        for rank, hit in enumerate(pinecone_hits):
            scores[hit.id] = scores.get(hit.id, 0) + self.alpha / (k + rank + 1)

        for rank, fid in enumerate(faiss_ids):
            doc_id = str(fid)
            scores[doc_id] = scores.get(doc_id, 0) + (1 - self.alpha) / (k + rank + 1)

        sorted_ids = sorted(scores, key=lambda x: scores[x], reverse=True)

        # Fetch metadata from Pinecone for top results
        docs = []
        for doc_id in sorted_ids[:self.top_k]:
            fetch = self.index.fetch(ids=[doc_id])
            if doc_id in fetch.vectors:
                v = fetch.vectors[doc_id]
                docs.append(Document(
                    page_content=v.metadata.get("text", ""),
                    metadata=v.metadata,
                ))
        return docs
