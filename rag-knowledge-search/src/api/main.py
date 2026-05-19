import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings
from ..rag.pipeline import RAGPipeline


class Settings(BaseSettings):
    openai_api_key: str
    pinecone_api_key: str
    pinecone_index: str
    faiss_index_path: str = "/app/data/faiss.index"
    retrieval_top_k: int = 20
    rerank_top_n: int = 5

    class Config:
        env_file = ".env"


settings = Settings()
pipeline = RAGPipeline(settings)
app = FastAPI(title="RAG Knowledge Search API", version="1.0.0")


class SearchRequest(BaseModel):
    query: str = Field(..., min_length=3, max_length=500)
    filters: dict | None = None


class SearchResponse(BaseModel):
    answer: str
    sources: list[dict]
    num_sources: int


@app.post("/search", response_model=SearchResponse)
async def search(request: SearchRequest):
    try:
        result = pipeline.query(request.query, filters=request.filters)
        return SearchResponse(**result)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
def health():
    return {"status": "healthy"}
