import os
from langchain_openai import ChatOpenAI, OpenAIEmbeddings
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
            alpha=0.6,
        )
        self.reranker = CrossEncoderReranker(top_n=config.rerank_top_n)
        self.prompt = PromptTemplate(
            template=SYSTEM_PROMPT,
            input_variables=["context", "question"],
        )

    def query(self, question: str, filters: dict | None = None) -> dict:
        candidates = self.retriever.get_relevant_documents(question, filters=filters)
        reranked = self.reranker.compress_documents(candidates, question)

        context = "\n\n---\n\n".join(
            f"[{doc.metadata['source']}]\n{doc.page_content}"
            for doc in reranked
        )

        messages = [
            {"role": "system", "content": self.prompt.format(context=context, question=question)},
        ]
        response = self.llm.invoke(messages)

        return {
            "answer": response.content,
            "sources": [d.metadata for d in reranked],
            "num_sources": len(reranked),
        }
